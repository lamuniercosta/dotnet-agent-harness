#!/usr/bin/env pwsh
# Runs Roslyn analyzer diagnostics (CA*/IDE* at warning+) from dotnet build on changed or specified C# files.
# Exits 1 when any matching diagnostic is found; 0 when clean; 2 (SKIPPED) when no files changed.
# Exits 1 (without analyzing) when no CA/IDE rule is enabled - see Assert-GateWired.
# CA1502 is excluded (handled by run-cyclomatic-complexity.ps1).
#
# Usage:
#   ./scripts/run-roslyn-analyzers.ps1
#   ./scripts/run-roslyn-analyzers.ps1 -BaseRef development
#   ./scripts/run-roslyn-analyzers.ps1 -Files "src/Foo.cs","tests/Bar.cs"
#   ./scripts/run-roslyn-analyzers.ps1 -All

[CmdletBinding()]
param(
    [string]$BaseRef = '',
    [string[]]$Files = @(),
    [string]$Solution = '',
    [switch]$All,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_gate-common.ps1')

$ExcludedRules = @('CA1502')

if ($Help) {
    Write-Output @"
Usage: run-roslyn-analyzers.ps1 [OPTIONS]

Runs Roslyn analyzer diagnostics at warning or error severity from dotnet build.
Severity is controlled in .editorconfig.

CA1502 is excluded; use run-cyclomatic-complexity.ps1 for complexity.

OPTIONS:
  -BaseRef <branch>   Git ref to diff against (default: the repo's default branch)
  -Files <paths...>   Explicit repo-relative .cs file paths to check
  -Solution <path>    Solution/project to build (default: auto-discovered)
  -All                Check the full solution (no file filter)
  -Help               Show this help

EXAMPLES:
  ./scripts/run-roslyn-analyzers.ps1
  ./scripts/run-roslyn-analyzers.ps1 -BaseRef origin/main
  ./scripts/run-roslyn-analyzers.ps1 -Files tests/MyTest.cs
"@
    exit 0
}

function Parse-RoslynDiagnostic {
    param([string]$Line)

    if ($Line -notmatch '^(?<path>.+?)\((?<line>\d+),\d+\):\s+(?<level>warning|error)\s+(?<rule>CA\d+|IDE\d+):\s+(?<message>.+)$') {
        return $null
    }

    return [PSCustomObject]@{
        Path    = $Matches.path.Replace('\', '/')
        Line    = [int]$Matches.line
        Level   = $Matches.level.ToUpperInvariant()
        Rule    = $Matches.rule
        Message = $Matches.message.Trim()
    }
}

$repoRoot = Get-RepoRoot

# Refuse to run at all if no CA/IDE rule is set to warning+ - a pass would be vacuous.
Assert-GateWired -RepoRoot $repoRoot -Gate 'roslyn'

$solutionPath = Resolve-BuildTarget -RepoRoot $repoRoot -Explicit $Solution
$baseRef = Resolve-BaseRef -RepoRoot $repoRoot -Explicit $BaseRef

$analyzeAll = Resolve-AnalysisScope -RepoRoot $repoRoot -All ([bool]$All) -Files $Files

$targetFiles = @()
if ($analyzeAll) {
    Write-Host 'Roslyn analyzers: analyzing full solution.'
}
else {
    $targetFiles = @(Get-TargetCsFiles -RepoRoot $repoRoot -BaseRef $baseRef -Files $Files)
}
$All = $analyzeAll

# SKIPPED (exit 2), not passed (exit 0). Nothing changed means nothing was
# analysed, and "verified nothing" is not the same result as "clean" - the
# contract this harness is built on. Reporting 0 here made a fresh install look
# green on a codebase no gate had ever read.
if (-not $All -and $targetFiles.Count -eq 0) {
    Write-Host "Roslyn analyzers: SKIPPED - no .cs files changed against $baseRef."
    Write-Host '  Nothing was verified. Run with -All to check the whole solution.'
    exit 2
}

Push-Location $repoRoot
try {
    if (-not $All) {
        Write-Host "Roslyn analyzers: checking $($targetFiles.Count) file(s) (base $baseRef):"
        $targetFiles | ForEach-Object { Write-Host "  $_" }
    }

    Write-Host 'Roslyn analyzers: building solution (this may take a minute)...'
    dotnet restore $solutionPath | Out-Null

    # --no-incremental is mandatory: analyzer diagnostics are emitted only when a
    # project actually recompiles. Without it every run after the first skips
    # compilation and the gate reports a pass having analysed nothing.
    $buildOutput = dotnet build $solutionPath --no-restore --no-incremental 2>&1 | ForEach-Object { $_.ToString() }
    $buildExit = $LASTEXITCODE

    if ($buildExit -ne 0) {
        $compilerErrors = $buildOutput | Where-Object {
            $_ -match ':\s+error\s+' -and $_ -notmatch ':\s+error\s+(CA|IDE)\d+:'
        }

        if ($compilerErrors) {
            Write-Host 'Roslyn analyzers: build failed with compiler errors. Fix build errors and retry.'
            $compilerErrors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
            exit 1
        }
    }

    # MSBuild reports the same diagnostic once per build node / target framework,
    # so collapse to one entry per site+rule.
    $issues = @(
        $buildOutput |
            ForEach-Object { Parse-RoslynDiagnostic -Line $_ } |
            Where-Object { $_ -ne $null -and $_.Rule -notin $ExcludedRules } |
            Sort-Object Path, Line, Rule -Unique
    )

    if (-not $All) {
        $issues = @($issues | Where-Object { Test-TargetsFile -IssuePath $_.Path -TargetFiles $targetFiles -RepoRoot $repoRoot })
    }

    if ($issues.Count -eq 0) {
        Write-Host 'Roslyn analyzers: passed (no CA/IDE warnings on target files).'
        exit 0
    }

    Write-Host "Roslyn analyzers: FAILED - $($issues.Count) diagnostic(s):"
    foreach ($issue in $issues) {
        $relativePath = if ([System.IO.Path]::IsPathRooted($issue.Path)) {
            [System.IO.Path]::GetRelativePath($repoRoot, $issue.Path).Replace('\', '/')
        }
        else {
            $issue.Path
        }

        Write-Host "  ${relativePath}:$($issue.Line) [$($issue.Level)] $($issue.Rule): $($issue.Message)"
    }

    Write-Host ''
    Write-Host 'Configure severities in .editorconfig. CA1502 is checked by run-cyclomatic-complexity.ps1.'
    exit 1
}
finally {
    Pop-Location
}
