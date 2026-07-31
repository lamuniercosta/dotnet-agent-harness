#!/usr/bin/env pwsh
# Runs CA1502 cyclomatic complexity analysis on changed or specified C# files.
# Exits 1 when any method exceeds the threshold in CodeMetricsConfig.txt; exits 0 when clean or no files to check.
# Exits 1 (without analyzing) when CA1502 is not actually enabled - see Assert-GateWired.
#
# Usage:
#   ./scripts/run-cyclomatic-complexity.ps1
#   ./scripts/run-cyclomatic-complexity.ps1 -BaseRef development
#   ./scripts/run-cyclomatic-complexity.ps1 -Files "src/Foo.cs","tests/Bar.cs"
#   ./scripts/run-cyclomatic-complexity.ps1 -Threshold 6
#   ./scripts/run-cyclomatic-complexity.ps1 -All

[CmdletBinding()]
param(
    [string]$BaseRef = '',
    [string[]]$Files = @(),
    [int]$Threshold = 0,
    [string]$Solution = '',
    [switch]$All,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @"
Usage: run-cyclomatic-complexity.ps1 [OPTIONS]

Runs CA1502 cyclomatic complexity analysis on new or modified C# files.

Threshold is configured in CodeMetricsConfig.txt at the repository root (default: 15).
Implementation gate is 15; the refactor gate is stricter - pass -Threshold 6.

OPTIONS:
  -BaseRef <branch>   Git ref to diff against (default: the repo's default branch)
  -Files <paths...>   Explicit repo-relative .cs file paths to check
  -Threshold <n>      Override CA1502 threshold (default: CodeMetricsConfig.txt)
  -Solution <path>    Solution/project to build (default: auto-discovered)
  -All                Check the full solution (no file filter)
  -Help               Show this help

EXAMPLES:
  ./scripts/run-cyclomatic-complexity.ps1
  ./scripts/run-cyclomatic-complexity.ps1 -Threshold 6
  ./scripts/run-cyclomatic-complexity.ps1 -Files tests/MyTest.cs
"@
    exit 0
}

function Get-ConfiguredThreshold {
    param([string]$RepoRoot)

    $configPath = Join-Path $RepoRoot 'CodeMetricsConfig.txt'
    if (-not (Test-Path $configPath)) {
        return 15
    }

    $match = Select-String -Path $configPath -Pattern '^\s*CA1502\s*:\s*(\d+)\s*$' |
        Select-Object -First 1

    if ($match) {
        return [int]$match.Matches[0].Groups[1].Value
    }

    return 15
}

function Parse-Ca1502Issue {
    <#
      Locale-tolerant. The CA1502 message body is translated, so rather than
      matching English prose we take the quoted tokens: the first is the member
      name, the first purely-numeric one is the complexity.
    #>
    param([string]$Line)

    if ($Line -notmatch '^(?<path>.+?)\((?<line>\d+),\d+\):\s+(?<level>warning|error)\s+CA1502:\s+(?<rest>.+)$') {
        return $null
    }

    # Capture every field now: the -match inside the loop below resets $Matches.
    # Strip any MSBuild node prefix ("2>C:\path\File.cs") off the path.
    $rest = $Matches.rest
    $path = $Matches.path -replace '^\d+>', ''
    $lineNumber = [int]$Matches.line
    $level = $Matches.level.ToUpperInvariant()

    $quoted = [regex]::Matches($rest, "'([^']*)'")
    if ($quoted.Count -lt 2) {
        return $null
    }

    $member = $quoted[0].Groups[1].Value
    $complexity = $null
    for ($i = 1; $i -lt $quoted.Count; $i++) {
        $value = $quoted[$i].Groups[1].Value
        if ($value -match '^\d+$') {
            $complexity = [int]$value
            break
        }
    }

    if ($null -eq $complexity) {
        return $null
    }

    return [PSCustomObject]@{
        Path       = $path.Replace('\', '/')
        Line       = $lineNumber
        Level      = $level
        Member     = $member
        Complexity = $complexity
    }
}

$repoRoot = Get-RepoRoot

# Refuse to run at all if CA1502 is not enabled - a pass here would be a lie.
Assert-GateWired -RepoRoot $repoRoot -Gate 'cyclomatic'

$solutionPath = Resolve-BuildTarget -RepoRoot $repoRoot -Explicit $Solution
$baseRef = Resolve-BaseRef -RepoRoot $repoRoot -Explicit $BaseRef
$threshold = if ($Threshold -gt 0) { $Threshold } else { Get-ConfiguredThreshold -RepoRoot $repoRoot }

$analyzeAll = Resolve-AnalysisScope -RepoRoot $repoRoot -All ([bool]$All) -Files $Files

$targetFiles = @()
if ($analyzeAll) {
    Write-Host 'Cyclomatic complexity: analyzing full solution.'
}
else {
    $targetFiles = @(Get-TargetCsFiles -RepoRoot $repoRoot -BaseRef $baseRef -Files $Files)
}
$All = $analyzeAll

if (-not $All -and $targetFiles.Count -eq 0) {
    Write-Host 'Cyclomatic complexity: no new or modified .cs files to check.'
    exit 0
}

# CA1502 decides what to EMIT from CodeMetricsConfig.txt - the analyzer never
# sees -Threshold. Filtering parsed output is not enough: at the configured 15,
# a -Threshold 6 run would never see anything between 7 and 15. So swap the
# config for the duration of the build and restore it afterwards.
$configPath = Join-Path $repoRoot 'CodeMetricsConfig.txt'
$configBackup = $null
if ($threshold -ne (Get-ConfiguredThreshold -RepoRoot $repoRoot)) {
    $configBackup = Get-Content $configPath -Raw
    $swapped = $configBackup -replace '(?m)^\s*CA1502\s*:\s*\d+\s*$', "CA1502: $threshold"
    if ($swapped -eq $configBackup) {
        $swapped = $configBackup.TrimEnd() + "`nCA1502: $threshold`n"
    }
    Set-Content -Path $configPath -Value $swapped -NoNewline
}

Push-Location $repoRoot
try {
    if (-not $All) {
        Write-Host "Cyclomatic complexity: checking $($targetFiles.Count) file(s) (threshold > $threshold, base $baseRef):"
        $targetFiles | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Host "Cyclomatic complexity: checking full solution (threshold > $threshold)."
    }

    Write-Host 'Cyclomatic complexity: building solution (this may take a minute)...'
    dotnet restore $solutionPath | Out-Null

    # --no-incremental is mandatory: analyzer diagnostics are emitted only when a
    # project actually recompiles. Without it every run after the first skips
    # compilation and the gate reports a pass having analysed nothing.
    $buildOutput = dotnet build $solutionPath --no-restore --no-incremental 2>&1 | ForEach-Object { $_.ToString() }
    $buildExit = $LASTEXITCODE

    if ($buildExit -ne 0) {
        $nonCaErrors = $buildOutput | Where-Object {
            $_ -match ':\s+error\s+' -and $_ -notmatch 'CA1502'
        }

        if ($nonCaErrors) {
            Write-Host 'Cyclomatic complexity: build failed with compiler errors. Fix build errors and retry.'
            $nonCaErrors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
            exit 1
        }
    }

    # MSBuild reports the same diagnostic once per build node / target framework,
    # so the same method can appear several times. Collapse to one per site.
    $issues = @(
        $buildOutput |
            ForEach-Object { Parse-Ca1502Issue -Line $_ } |
            Where-Object { $_ -ne $null } |
            Sort-Object Path, Line, Member -Unique
    )

    if (-not $All) {
        $issues = @($issues | Where-Object { Test-TargetsFile -IssuePath $_.Path -TargetFiles $targetFiles -RepoRoot $repoRoot })
    }

    if ($issues.Count -eq 0) {
        Write-Host "Cyclomatic complexity: passed (no methods exceed threshold of $threshold)."
        exit 0
    }

    Write-Host "Cyclomatic complexity: FAILED - $($issues.Count) method(s) exceed threshold of ${threshold}:"
    foreach ($issue in $issues) {
        $relativePath = if ([System.IO.Path]::IsPathRooted($issue.Path)) {
            [System.IO.Path]::GetRelativePath($repoRoot, $issue.Path).Replace('\', '/')
        }
        else {
            $issue.Path
        }

        Write-Host "  ${relativePath}:$($issue.Line) [$($issue.Level)] $($issue.Member) - complexity $($issue.Complexity) (max $threshold)"
    }

    Write-Host ''
    Write-Host "Threshold is configured in CodeMetricsConfig.txt (CA1502: $threshold)."
    Write-Host 'Fix by extracting helpers / early returns / guard clauses - not by suppressing.'
    exit 1
}
finally {
    Pop-Location
    if ($configBackup) {
        Set-Content -Path $configPath -Value $configBackup -NoNewline
    }
}
