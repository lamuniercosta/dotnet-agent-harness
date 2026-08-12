#!/usr/bin/env pwsh

<#
.SYNOPSIS
  Runs a coding task through Junie using the OpenRouter API key in the environment.
  The task text is passed to Junie on the command line; do not include secrets in -Task.

.DESCRIPTION
  Uses OPENROUTER_API_KEY as the source credential and passes it to Junie only
  through JUNIE_OPENROUTER_API_KEY for the child process. The key is never
  written to configuration, emitted to the terminal, or placed in the command
  line. GLM 5.2 is the default for every tier; pass -Model to try another
  OpenRouter model without changing the route map.

.PARAMETER Task
  The coding task to give Junie.

.PARAMETER Tier
  The route-map tier. It determines Junie's reasoning effort.

.PARAMETER Model
  An OpenRouter model id. Defaults to z-ai/glm-5.2.

.PARAMETER RepoRoot
  Project directory supplied to Junie. Defaults to the current directory.

.EXAMPLE
  ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier deep -Task 'Implement the approved tasks.md plan.'

.EXAMPLE
  ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier balanced -Model qwen/qwen3-coder -Task 'Review this diff for regressions.'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Task,

    [ValidateSet('fast', 'balanced', 'deep')]
    [string]$Tier = 'deep',

    [string]$Model = 'z-ai/glm-5.2',

    [string]$RepoRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) {
    throw 'OPENROUTER_API_KEY is not set in this process. Set it in your user environment, then open a new terminal.'
}

$repoPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$effort = switch ($Tier) {
    'fast' { 'low' }
    'balanced' { 'medium' }
    'deep' { 'high' }
}

$junieArguments = @(
    '--provider', 'openrouter',
    '--model', $Model,
    '--effort', $effort,
    '--project', $repoPath,
    '--task', $Task
)

Write-Host "Provider: OpenRouter (via Junie)"
Write-Host "Model:    $Model"
Write-Host "Tier:     $Tier (effort=$effort)"
Write-Host "Project:  $repoPath"
if ($WhatIfPreference) {
    Write-Host 'Dry run: Junie will not be launched.'
}

if ($PSCmdlet.ShouldProcess("Junie with OpenRouter model '$Model'", 'Run coding task')) {
    if (-not (Get-Command junie -ErrorAction SilentlyContinue)) {
        throw 'Junie CLI is required. Install it from https://junie.jetbrains.com/cli, then try again.'
    }

    # Avoid --openrouter-api-key: command-line arguments can be inspected by
    # other local processes. Junie reads this variable directly.
    $previousKey = $env:JUNIE_OPENROUTER_API_KEY
    try {
        $env:JUNIE_OPENROUTER_API_KEY = $env:OPENROUTER_API_KEY
        & junie @junieArguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($null -eq $previousKey) {
            Remove-Item Env:JUNIE_OPENROUTER_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:JUNIE_OPENROUTER_API_KEY = $previousKey
        }
    }

    exit $exitCode
}
