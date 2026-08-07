#!/usr/bin/env pwsh
# Runs JetBrains InspectCode (same engine as Rider/ReSharper) on changed or specified C# files.
# Exits 1 when WARNING+ inspections are found or analysis cannot complete; 0 when clean;
# 2 (SKIPPED) when no files match the requested scope.
# Exits 1 (without inspecting) when the jb tool is not in the manifest - see Assert-GateWired.
#
# These are ReSharper inspections, NOT Roslyn CA/IDE warnings - dotnet build will not catch them.
#
# Usage:
#   ./scripts/run-jetbrains-inspectcode.ps1
#   ./scripts/run-jetbrains-inspectcode.ps1 -BaseRef development
#   ./scripts/run-jetbrains-inspectcode.ps1 -Files "src/Foo.cs","tests/Bar.cs"
#   ./scripts/run-jetbrains-inspectcode.ps1 -All

[CmdletBinding()]
param(
    [string]$BaseRef = '',
    [string[]]$Files = @(),
    [ValidateSet('INFO', 'HINT', 'SUGGESTION', 'WARNING', 'ERROR')]
    [string]$MinSeverity = 'WARNING',
    [string]$Solution = '',
    [switch]$All,
    [switch]$NoBuild,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_gate-common.ps1')

$SeverityRank = @{
    INFO       = 0
    HINT       = 1
    SUGGESTION = 2
    WARNING    = 3
    ERROR      = 4
}

if ($Help) {
    Write-Output @"
Usage: run-jetbrains-inspectcode.ps1 [OPTIONS]

Runs JetBrains InspectCode on new or modified C# files (same inspections as Rider).

OPTIONS:
  -BaseRef <branch>   Git ref to diff against (default: the repo's default branch)
  -Files <paths...>   Explicit repo-relative .cs file paths to inspect
  -MinSeverity        Minimum severity to fail on (default: WARNING)
  -Solution <path>    Solution to inspect (default: auto-discovered)
  -All                Inspect the full solution (no file filter)
  -NoBuild            Skip inspectcode's internal build (use when already built)
  -Help               Show this help

EXAMPLES:
  ./scripts/run-jetbrains-inspectcode.ps1
  ./scripts/run-jetbrains-inspectcode.ps1 -BaseRef origin/main
  ./scripts/run-jetbrains-inspectcode.ps1 -Files tests/MyTest.cs
"@
    exit 0
}

function Get-IncludePatterns {
    param(
        [string[]]$RepoRelativePaths
    )

    if ($RepoRelativePaths.Count -eq 0) {
        return @()
    }

    return $RepoRelativePaths | ForEach-Object {
        $normalized = $_.Replace('\', '/')
        $fileName = [System.IO.Path]::GetFileName($normalized)
        "**/$fileName"
    }
}

function Test-MeetsMinSeverity {
    param(
        [string]$Level,
        [string]$Minimum
    )

    $normalized = if ($Level) { $Level.ToUpperInvariant() } else { 'WARNING' }
    if (-not $SeverityRank.ContainsKey($normalized)) {
        $normalized = 'WARNING'
    }

    return $SeverityRank[$normalized] -ge $SeverityRank[$Minimum]
}

function Format-Issue {
    param($Result, $RepoRoot, $SolutionDir)

    $location = $Result.locations[0].physicalLocation
    $uri = $location.artifactLocation.uri
    $line = $location.region.startLine
    $message = $Result.message.text
    $ruleId = $Result.ruleId
    $level = $Result.level

    $relativePath = if ($uri -match '^\.\./') {
        $uri.Replace('../', '')
    }
    elseif ([System.IO.Path]::IsPathRooted($uri)) {
        [System.IO.Path]::GetRelativePath($RepoRoot, $uri).Replace('\', '/')
    }
    else {
        [System.IO.Path]::GetRelativePath($SolutionDir, $uri).Replace('\', '/').TrimStart('./')
    }

    return "${relativePath}:${line} [$level] $ruleId - $message"
}

$repoRoot = Get-RepoRoot

# Exit 2 (SKIPPED), never 0. A gate turned off is the clearest case of "did not
# run" - reporting it as a pass would be the same lie as a gate whose analyzer
# is not wired.
if (-not (Get-HarnessValue 'gates.inspectCode.enabled' -RepoRoot $repoRoot)) {
    Write-Host 'InspectCode: SKIPPED - disabled in harness.yml (gates.inspectCode.enabled: false).'
    Write-Host '  Roslyn analyzers still run, but nothing else in the harness reports duplication.'
    exit 2
}

# Refuse to run at all if the jb tool is not provisioned.
Assert-GateWired -RepoRoot $repoRoot -Gate 'inspectcode'

$solutionPath = Resolve-BuildTarget -RepoRoot $repoRoot -Explicit $Solution
$solutionDir = Split-Path $solutionPath -Parent
$baseRef = Resolve-BaseRef -RepoRoot $repoRoot -Explicit $BaseRef
$reportDir = Join-Path $repoRoot 'artifacts/inspectcode'
$reportPath = Join-Path $reportDir 'inspect-report.sarif.json'

$analyzeAll = Resolve-AnalysisScope -RepoRoot $repoRoot -All ([bool]$All) -Files $Files

$targetFiles = @()
if ($analyzeAll) {
    Write-Host 'InspectCode: analyzing full solution.'
}
else {
    $targetFiles = @(Get-TargetCsFiles -RepoRoot $repoRoot -BaseRef $baseRef -Files $Files)
}
$All = $analyzeAll

# SKIPPED (exit 2), not passed (exit 0). See run-roslyn-analyzers.ps1 - the same
# reasoning applies: nothing changed means nothing was inspected.
if (-not $All -and $targetFiles.Count -eq 0) {
    Write-Host "InspectCode: SKIPPED - no .cs files changed against $baseRef."
    Write-Host '  Nothing was verified. Run with -All to inspect the whole solution.'
    exit 2
}

Push-Location $repoRoot
try {
    Write-Host 'InspectCode: restoring dotnet tools...'
    dotnet tool restore | Out-Null

    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    if (Test-Path $reportPath) {
        Remove-Item $reportPath -Force
    }

    $jbArgs = @(
        'jb', 'inspectcode', $solutionPath,
        "--severity=$MinSeverity",
        '--format=Sarif',
        "--output=$reportPath",
        '--settings=.editorconfig'
    )

    if ($NoBuild) {
        $jbArgs += '--no-build'
    }

    if (-not $All) {
        $includePatterns = Get-IncludePatterns -RepoRelativePaths $targetFiles
        $includeValue = ($includePatterns -join ';')
        Write-Host "InspectCode: analyzing $($targetFiles.Count) file(s) (base $baseRef):"
        $targetFiles | ForEach-Object { Write-Host "  $_" }
        $jbArgs += "--include=$includeValue"
    }

    Write-Host 'InspectCode: running analysis (this may take a minute)...'
    & dotnet @jbArgs
    $inspectExit = $LASTEXITCODE

    if ($inspectExit -eq 3) {
        Write-Host 'InspectCode: SKIPPED - no matching files in solution scope.'
        Write-Host '  Nothing was verified. Check the requested files and solution scope.'
        exit 2
    }

    if ($inspectExit -eq 4) {
        throw 'InspectCode could not complete analysis (exit 4). Fix compiler errors in the target files and retry.'
    }

    if ($inspectExit -ne 0 -and -not (Test-Path $reportPath)) {
        throw "InspectCode failed with exit code $inspectExit and produced no report."
    }

    if (-not (Test-Path $reportPath)) {
        Write-Host 'GATE COULD NOT RUN: InspectCode exited successfully but produced no SARIF report.' -ForegroundColor Red
        Write-Host "  Expected report: $reportPath"
        Write-Host '  Retry the gate and inspect the JetBrains tool output if the report is still absent.'
        exit 1
    }

    $sarif = Get-Content $reportPath -Raw | ConvertFrom-Json
    $results = @($sarif.runs[0].results)
    $failures = @($results | Where-Object { Test-MeetsMinSeverity -Level $_.level -Minimum $MinSeverity })

    if ($failures.Count -eq 0) {
        Write-Host "InspectCode: passed (no $MinSeverity+ issues)."
        exit 0
    }

    Write-Host "InspectCode: FAILED - $($failures.Count) issue(s) at $MinSeverity or higher:"
    foreach ($issue in $failures) {
        Write-Host "  $(Format-Issue -Result $issue -RepoRoot $repoRoot -SolutionDir $solutionDir)"
    }

    Write-Host ""
    Write-Host "Full report: $reportPath"
    Write-Host 'When a finding is intentional, use a targeted ReSharper suppression comment rather than ignoring it.'
    exit 1
}
finally {
    Pop-Location
}
