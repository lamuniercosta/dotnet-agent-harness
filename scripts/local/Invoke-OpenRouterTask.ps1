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
  command line. Each tier has its own default OpenRouter model:
  deepseek/deepseek-v4-flash for fast, deepseek/deepseek-v4-pro for balanced,
  and z-ai/glm-5.2 for deep, which deliberately stays put so the existing
  /code-review route does not change behavior. Pass -Model to use a
  different OpenRouter model for one run without touching the route map; an
  explicit -Model always overrides the tier default.

  The generated profile also sets extraBody.provider.sort to "price", so
  OpenRouter routes each request to the cheapest endpoint serving that model
  id. Reasoning effort never goes in the profile: it travels only on
  Junie's --effort flag, because extraBody wins Junie's request merge and a
  profile is keyed by model, not by tier -- a `fast` run that created the
  profile first would otherwise pin `low` effort onto a later `deep` run of
  the same model. An existing profile is rewritten whenever its rendered
  content no longer matches what's on disk, so new fields reach profiles
  that were written before this script grew them.

.PARAMETER Task
  The coding task to give Junie. Piped as JSON on stdin.

.PARAMETER Tier
  The route-map tier. It determines Junie's reasoning effort (fast=low,
  balanced=medium, deep=high) and, unless -Model is given, the default
  OpenRouter model: deepseek/deepseek-v4-flash (fast), deepseek/deepseek-v4-pro
  (balanced), or z-ai/glm-5.2 (deep, unchanged so /code-review's route does
  not shift).

.PARAMETER Model
  An OpenRouter model id. Defaults to the tier's route-map model (see the
  -Tier parameter); an explicit value here always overrides that default.

.PARAMETER RepoRoot
  Project directory supplied to Junie. Defaults to the current directory.

.PARAMETER ModelDir
  Directory holding Junie custom model profiles. Defaults to ~/.junie/models.

.PARAMETER ProfileOnly
  Render and write (or update) the Junie custom model profile, report what
  happened, and exit 0 without launching Junie. Exists so the profile logic
  is testable without spending credits or launching Junie, and to
  pre-provision a profile on its own. Honors -WhatIf like every other write
  in this script.

.EXAMPLE
  ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier deep -Task 'Implement the approved tasks.md plan.'

.EXAMPLE
  ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier balanced -Model qwen/qwen3-coder -Task 'Review this diff for regressions.'

.EXAMPLE
  ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier fast -ProfileOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Task,

    [ValidateSet('fast', 'balanced', 'deep')]
    [string]$Tier = 'deep',

    [string]$Model = '',

    [string]$RepoRoot = (Get-Location).Path,

    # $HOME, not $env:USERPROFILE: the latter is null off Windows, and the
    # separator has to be joined rather than written, or '.junie\models'
    # becomes one literal filename on Linux. Junie itself is Windows-first
    # here, but the self-test runs on both CI legs.
    [string]$ModelDir = (Join-Path (Join-Path $HOME '.junie') 'models'),

    [switch]$ProfileOnly
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

# Per-tier default OpenRouter model (price per 1M in/out tokens, verified
# 2026-08-25, all at 1.05M context): fast -> deepseek/deepseek-v4-flash
# ($0.077/$0.154), balanced -> deepseek/deepseek-v4-pro ($0.556/$1.112). deep
# deliberately stays on z-ai/glm-5.2 ($1.190/$3.740) so the existing
# /code-review route does not change behavior.
$tierDefaultModels = @{
    fast     = 'deepseek/deepseek-v4-flash'
    balanced = 'deepseek/deepseek-v4-pro'
    deep     = 'z-ai/glm-5.2'
}

# '' is the "not supplied" sentinel, not a real model id -- a hardcoded
# default string couldn't tell "user asked for this" apart from "user asked
# for the tier default that happens to match it". An explicit -Model always
# wins over the tier default.
if ([string]::IsNullOrEmpty($Model)) {
    $Model = $tierDefaultModels[$Tier]
}

$profileName = 'openrouter-' + ($Model -replace '[^A-Za-z0-9._-]', '-')
$profilePath = Join-Path $ModelDir ($profileName + '.json')

# provider.sort: "price" makes OpenRouter route to the cheapest endpoint
# serving this model id (verified live: returns 200). Two omissions below
# are deliberate, both verified the hard way:
#   - reasoning_effort must NOT be added to extraBody. The profile is keyed
#     by model id, but effort is per-tier, and extraBody wins Junie's
#     request merge over its own --effort flag (confirmed by wire capture).
#     A `fast` run that creates the profile first would otherwise silently
#     pin `low` effort onto a later `deep` run of the same model. Effort
#     must keep travelling on Junie's --effort flag only.
#   - a nested reasoning: { effort: ... } object must NOT be added either.
#     Junie already sends a flat reasoning_effort; sending both returns
#     HTTP 400: "reasoning_effort" and "reasoning.effort" are both provided
#     with conflicting values.
# provider.max_price is deliberately not set: a cap below every endpoint's
# price returns HTTP 404 (no endpoints matched) rather than routing
# somewhere cheaper -- it fails closed, not gracefully.
$profileJson = @"
{
  "baseUrl": "https://openrouter.ai/api/v1/chat/completions",
  "id": "$Model",
  "apiType": "OpenAICompletion",
  "apiKey": "`${OPENROUTER_API_KEY}",
  "temperature": 0.7,
  "extraBody": {
    "provider": { "sort": "price" }
  }
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

# The shape this script rendered before it grew extraBody. Recognizing it is
# what makes an in-place upgrade safe: a file matching it was written by an
# older run of this script, so rewriting it loses nothing.
$legacyProfileJson = @"
{
  "baseUrl": "https://openrouter.ai/api/v1/chat/completions",
  "id": "$Model",
  "apiType": "OpenAICompletion",
  "apiKey": "`${OPENROUTER_API_KEY}",
  "temperature": 0.7
}
"@

# Compare against what's on disk (rather than only checking existence) so a
# profile written before this script grew new fields still gets them.
#
# Only profiles this script wrote are ever rewritten. The derived name is a
# plain function of the model id, so a hand-tuned profile can legitimately
# already own that filename -- a tuned openrouter-stealth-ox-alpha.json with
# its own temperature, context length, and extraBody is a real case. Clobbering
# it would destroy deliberate work and give no sign it had happened, so an
# unrecognized profile is left exactly as it is and used as-is, with a warning.
# Same rule ADR 0005 sets for manifest-owned skill copies: do not mutate what
# you do not own.
$existingProfileJson = $null
if (Test-Path -LiteralPath $profilePath) {
    $existingProfileJson = Get-Content -LiteralPath $profilePath -Raw
}
$profileIsCurrent = ($null -ne $existingProfileJson) -and ($existingProfileJson -eq $profileJson)
$profileIsOurs = ($null -eq $existingProfileJson) -or
                 $profileIsCurrent -or
                 ($existingProfileJson -eq $legacyProfileJson)

if (-not $profileIsOurs) {
    Write-Warning "Leaving hand-tuned Junie profile untouched: $profilePath"
    Write-Warning 'It was not written by this script, so its settings win. Delete it to get the generated profile back.'
}
elseif (-not $profileIsCurrent) {
    if ($PSCmdlet.ShouldProcess($profilePath, 'Write Junie custom model profile')) {
        New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
        [System.IO.File]::WriteAllText($profilePath, $profileJson, [System.Text.UTF8Encoding]::new($false))
        if ($null -eq $existingProfileJson) {
            Write-Host "Created Junie custom model profile: $profilePath"
        }
        else {
            Write-Host "Updated Junie custom model profile: $profilePath"
        }
    }
}

if ($ProfileOnly) {
    Write-Host 'Profile-only run: Junie was not launched.'
    exit 0
}

if ($PSCmdlet.ShouldProcess("Junie with OpenRouter model '$Model'", 'Run coding task')) {
    if (-not (Get-Command junie -ErrorAction SilentlyContinue)) {
        throw 'Junie CLI is required. Install it from https://junie.jetbrains.com/cli, then try again.'
    }

    # Avoid --openrouter-api-key: command-line arguments can be inspected by
    # other local processes. Junie resolves the profile's ${OPENROUTER_API_KEY}
    # reference from its inherited environment.
    $taskPayload = @{ task = $Task } | ConvertTo-Json -Compress
    $taskPayload | & junie @junieArguments

    exit $LASTEXITCODE
}
