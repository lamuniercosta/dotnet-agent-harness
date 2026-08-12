#!/usr/bin/env pwsh

<#
.SYNOPSIS
  Runs a coding task through Junie using the OpenRouter API key in the environment.
  The task text is piped to Junie as JSON on stdin, so it never appears on the
  command line; still, do not include secrets in -Task.

.DESCRIPTION
  Junie's --model flag accepts only built-in aliases or custom:<profile-id>; raw
  OpenRouter ids such as z-ai/glm-5.2 are rejected client-side. This launcher
  therefore maintains a custom model profile per OpenRouter id under
  ~/.junie/models/ (override with -ModelDir) and invokes Junie with
  --model custom:<derived-name>. The profile holds an environment reference
  ("${OPENROUTER_API_KEY}"), never the key itself.

  The task is sent as JSON on stdin (--input-format=json) because Junie's
  readPipedInput path crashes with ERROR_INVALID_FUNCTION ("Função incorreta")
  when stdin is redirected without piped input on Windows. Piping the payload is
  the verified workaround and also keeps the task text off the command line.

  Uses OPENROUTER_API_KEY as the source credential; Junie resolves the
  profile's environment reference from its inherited environment. The key is
  never written to configuration, emitted to the terminal, or placed in the
  command line. GLM 5.2 is the default for every tier; pass -Model to try
  another OpenRouter model without changing the route map.

.PARAMETER Task
  The coding task to give Junie. Piped as JSON on stdin.

.PARAMETER Tier
  The route-map tier. It determines Junie's reasoning effort.

.PARAMETER Model
  An OpenRouter model id. Defaults to z-ai/glm-5.2.

.PARAMETER RepoRoot
  Project directory supplied to Junie. Defaults to the current directory.

.PARAMETER ModelDir
  Directory holding Junie custom model profiles. Defaults to ~/.junie/models.

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

    [string]$RepoRoot = (Get-Location).Path,

    [string]$ModelDir = (Join-Path $env:USERPROFILE '.junie\models')
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

$profileName = 'openrouter-' + ($Model -replace '[^A-Za-z0-9._-]', '-')
$profilePath = Join-Path $ModelDir ($profileName + '.json')
$profileJson = @"
{
  "baseUrl": "https://openrouter.ai/api/v1/chat/completions",
  "id": "$Model",
  "apiType": "OpenAICompletion",
  "apiKey": "`${OPENROUTER_API_KEY}",
  "temperature": 0.7
}
"@

$junieArguments = @(
    '--skip-update-check',
    '--input-format=json',
    '--model', "custom:$profileName",
    '--effort', $effort,
    '--project', $repoPath
)

Write-Host "Provider: OpenRouter (via Junie)"
Write-Host "Model:    $Model"
Write-Host "Profile:  custom:$profileName ($profilePath)"
Write-Host "Tier:     $Tier (effort=$effort)"
Write-Host "Project:  $repoPath"
if ($WhatIfPreference) {
    Write-Host 'Dry run: Junie will not be launched.'
}

if ($PSCmdlet.ShouldProcess("Junie with OpenRouter model '$Model'", 'Run coding task')) {
    if (-not (Get-Command junie -ErrorAction SilentlyContinue)) {
        throw 'Junie CLI is required. Install it from https://junie.jetbrains.com/cli, then try again.'
    }

    if (-not (Test-Path -LiteralPath $profilePath)) {
        New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
        [System.IO.File]::WriteAllText($profilePath, $profileJson, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Created Junie custom model profile: $profilePath"
    }

    # Avoid --openrouter-api-key: command-line arguments can be inspected by
    # other local processes. Junie resolves the profile's ${OPENROUTER_API_KEY}
    # reference from its inherited environment.
    $taskPayload = @{ task = $Task } | ConvertTo-Json -Compress
    $taskPayload | & junie @junieArguments

    exit $LASTEXITCODE
}
