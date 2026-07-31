#!/usr/bin/env pwsh
# Installs the static-analysis gates into a target repository.
#
# Copies the gate scripts and the analyzer wiring they depend on. Never
# clobbers existing config: if a file already exists and differs, it is left
# alone and reported so you can merge by hand.
#
# Usage:
#   ./scripts/install-gates.ps1 F:\Dev\MyRepo
#   ./scripts/install-gates.ps1 F:\Dev\MyRepo -WhatIf
#
# Deliberately 5.1-compatible so it runs anywhere, even though the gate
# scripts it installs require PowerShell 7 (pwsh).

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TargetRepo,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Write-Output @"
Usage: install-gates.ps1 <target-repo> [-WhatIf]

Installs the static-analysis gate scripts and their analyzer wiring.

Copied into <target-repo>:
  scripts/_gate-common.ps1
  scripts/run-roslyn-analyzers.ps1
  scripts/run-cyclomatic-complexity.ps1
  scripts/run-jetbrains-inspectcode.ps1
  scripts/run-property-tests.ps1
  scripts/run-gherkin-mutation.ps1
  Directory.Build.props        (skipped if present)
  CodeMetricsConfig.txt        (skipped if present)
  .config/dotnet-tools.json    (skipped if present)
  .editorconfig                (gate section appended if absent)
"@
    exit 0
}

$srcScripts = $PSScriptRoot
# Templates are a sibling of scripts/ inside the pack, not a child of it.
$srcTemplates = Join-Path (Split-Path $srcScripts -Parent) 'templates'

if (-not (Test-Path $TargetRepo)) {
    throw "Target repo not found: $TargetRepo"
}

$TargetRepo = (Resolve-Path $TargetRepo).Path
$results = @()

function Add-Result {
    param([string]$Item, [string]$Status, [string]$Note = '')
    $script:results += [PSCustomObject]@{ Item = $Item; Status = $Status; Note = $Note }
}

# ── Gate scripts: always refreshed, they are ours to own ─────────────────────
$destScripts = Join-Path $TargetRepo 'scripts'
if (-not (Test-Path $destScripts)) {
    if ($PSCmdlet.ShouldProcess($destScripts, 'create directory')) {
        New-Item -ItemType Directory -Force -Path $destScripts | Out-Null
    }
}

$gateScripts = @(
    '_gate-common.ps1',
    'run-roslyn-analyzers.ps1',
    'run-cyclomatic-complexity.ps1',
    'run-jetbrains-inspectcode.ps1',
    'run-property-tests.ps1',
    'run-gherkin-mutation.ps1',
    'run-vulnerable-packages.ps1',
    '_harness-config.ps1'
)

foreach ($name in $gateScripts) {
    $src = Join-Path $srcScripts $name
    if (-not (Test-Path $src)) {
        Add-Result $name 'MISSING' 'not found in source pack'
        continue
    }

    $dest = Join-Path $destScripts $name
    $existed = Test-Path $dest
    if ($PSCmdlet.ShouldProcess($dest, 'copy gate script')) {
        Copy-Item $src $dest -Force
    }
    Add-Result "scripts/$name" $(if ($existed) { 'UPDATED' } else { 'ADDED' })
}

# ── Config files: never clobber ──────────────────────────────────────────────
$configs = @(
    @{ Src = 'Directory.Build.props'; Dest = 'Directory.Build.props' },
    @{ Src = 'CodeMetricsConfig.txt'; Dest = 'CodeMetricsConfig.txt' },
    @{ Src = 'BannedSymbols.txt'; Dest = 'BannedSymbols.txt' },
    @{ Src = 'dotnet-tools.json'; Dest = '.config/dotnet-tools.json' }
)

foreach ($cfg in $configs) {
    $src = Join-Path $srcTemplates $cfg.Src
    $dest = Join-Path $TargetRepo $cfg.Dest

    if (Test-Path $dest) {
        Add-Result $cfg.Dest 'SKIPPED' 'already exists - merge by hand if needed'
        continue
    }

    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) {
        if ($PSCmdlet.ShouldProcess($destDir, 'create directory')) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess($dest, 'add config')) {
        Copy-Item $src $dest -Force
    }
    Add-Result $cfg.Dest 'ADDED'
}

# ── .editorconfig: append the gate section if not already present ────────────
$editorConfig = Join-Path $TargetRepo '.editorconfig'
$gateBlock = Get-Content (Join-Path $srcTemplates 'editorconfig-gates.ini') -Raw

if (-not (Test-Path $editorConfig)) {
    if ($PSCmdlet.ShouldProcess($editorConfig, 'create with gate section')) {
        "root = true`r`n" | Set-Content $editorConfig -Encoding UTF8
        Add-Content $editorConfig $gateBlock -Encoding UTF8
    }
    Add-Result '.editorconfig' 'ADDED'
}
elseif ((Get-Content $editorConfig -Raw) -match 'dotnet_diagnostic\.CA1502\.severity') {
    Add-Result '.editorconfig' 'SKIPPED' 'gate section already present'
}
else {
    if ($PSCmdlet.ShouldProcess($editorConfig, 'append gate section')) {
        Add-Content $editorConfig "`r`n$gateBlock" -Encoding UTF8
    }
    Add-Result '.editorconfig' 'APPENDED'
}

# ── Report ───────────────────────────────────────────────────────────────────
Write-Output ''
Write-Output "Gate install -> $TargetRepo"
Write-Output ''
$results | Format-Table -AutoSize Item, Status, Note | Out-String | Write-Output

$skipped = @($results | Where-Object { $_.Status -eq 'SKIPPED' })
if ($skipped.Count -gt 0) {
    Write-Output 'Some config was left untouched because it already exists.'
    Write-Output 'Verify the gates are actually wired by running:'
    Write-Output '  ./scripts/run-cyclomatic-complexity.ps1 -All'
    Write-Output 'It exits 1 with remediation if anything is missing.'
    Write-Output ''
}

Write-Output 'Next: dotnet tool restore   (provisions jb + stryker)'
