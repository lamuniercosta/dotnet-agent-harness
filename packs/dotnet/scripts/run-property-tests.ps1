#!/usr/bin/env pwsh
# Runs xUnit tests tagged with Category=Property (FsCheck property tests).
# Exits 1 when any property test fails or the run could not be interpreted;
# 0 when all pass; 2 (SKIPPED) when none are tagged, or all matched ones skipped.
#
# Usage:
#   ./scripts/run-property-tests.ps1
#   ./scripts/run-property-tests.ps1 -Project tests/My.UnitTests/My.UnitTests.csproj

[CmdletBinding()]
param(
    [string]$Project = '',
    [string]$Category = 'Property',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @"
Usage: run-property-tests.ps1 [OPTIONS]

Runs dotnet test with filter Category=Property. Defaults to the whole solution,
so every test project is covered without naming them.

OPTIONS:
  -Project <path>   Test project or solution to run (default: auto-discovered)
  -Category <name>  Trait category to filter on (default: Property)
  -Help             Show this help

EXAMPLES:
  ./scripts/run-property-tests.ps1
  ./scripts/run-property-tests.ps1 -Project tests/My.UnitTests/My.UnitTests.csproj
"@
    exit 0
}

$repoRoot = Get-RepoRoot

if (-not (Get-HarnessValue 'gates.propertyTests.enabled' -RepoRoot $repoRoot)) {
    Write-Host 'Property tests: SKIPPED - disabled in harness.yml (gates.propertyTests.enabled: false).'
    exit 2
}

# One project per run, deliberately.
#
# Running the whole solution in a single `dotnet test` interleaves every
# assembly's output, and the signals that classify a run - the no-match message,
# the counts - are per assembly while the exit code is not. That made "this
# assembly had no matching tests" indistinguishable from "that assembly died
# before reporting", which produced a SKIPPED verdict over a solution whose
# property tests had passed, and later a SKIPPED verdict over a failed run.
#
# Enumerating projects costs one `dotnet test` each and makes the whole class of
# confusion impossible: one project, one result, no interleaving to untangle.
# A solution is expanded to its test projects rather than run whole, including
# when the caller names one explicitly: handing the classifier interleaved output
# is the one thing that must never happen, whichever path got us here.
$targets = if ($Project) {
    $resolved = Resolve-BuildTarget -RepoRoot $repoRoot -Explicit $Project
    if ($resolved -like '*.csproj') { @($resolved) } else { Get-TestProjects -RepoRoot $repoRoot }
}
else {
    Get-TestProjects -RepoRoot $repoRoot
}

# No discoverable test project: fall back to the solution rather than inventing a
# verdict. Whatever `dotnet test` reports about it is still classified below.
if ($targets.Count -eq 0) {
    $targets = @(Resolve-BuildTarget -RepoRoot $repoRoot -Explicit '')
}

Push-Location $repoRoot
try {
    $ran = 0
    $skippedTotal = 0
    $failed = @()
    $unreadable = @()

    foreach ($target in $targets) {
        $name = Split-Path $target -Leaf
        Write-Host "Property tests: $name (Category=$Category)..."

        $output = dotnet test $target --filter "Category=$Category" --verbosity minimal 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Write-Host $_ }

        $outcome = Get-TestRunOutcome -Output $output -ExitCode $exitCode
        $skippedTotal += $outcome.Skipped

        switch ($outcome.Outcome) {
            'Ran' {
                $ran += $outcome.Executed
                if ($exitCode -ne 0) { $failed += $name }
            }
            'NothingMatched' { }
            default { $unreadable += "$name ($($outcome.Outcome), exit $exitCode)" }
        }
    }

    # An unreadable run is not a skip and not a pass. Reported first: if one
    # project could not be interpreted, no verdict over the rest is trustworthy.
    if ($unreadable.Count -gt 0) {
        Write-Host ''
        Write-Host 'GATE COULD NOT RUN: a test project produced no readable result.' -ForegroundColor Red
        foreach ($u in $unreadable) { Write-Host "  $u" }
        Write-Host '  Nothing accounts for the missing tests - a build error, a crashed test host,'
        Write-Host '  or an assembly that could not be discovered.'
        Write-Host "  Run it directly to see why: dotnet test <project> --filter `"Category=$Category`""
        exit 1
    }

    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host "Property tests: FAILED in $($failed -join ', ') ($ran test(s) executed)."
        exit 1
    }

    if ($ran -gt 0) {
        Write-Host ''
        Write-Host "Property tests: passed ($ran test(s) executed across $($targets.Count) project(s))."
        exit 0
    }

    # Nothing executed anywhere. SKIPPED (exit 2), never passed - a gate that
    # verified nothing has not earned a green verdict.
    Write-Host ''
    if ($skippedTotal -gt 0) {
        # They exist and are tagged; they just never ran. Telling someone to add
        # property tests they already have sends them the wrong way.
        Write-Host "Property tests: SKIPPED - $skippedTotal test(s) matched but every one was skipped."
        Write-Host '  Nothing was verified. Remove the Skip attribute, or set'
        Write-Host '  gates.propertyTests.enabled: false in harness.yml to opt out deliberately.'
        exit 2
    }

    Write-Host "Property tests: SKIPPED - no tests tagged Category=$Category."
    Write-Host '  The refactor gate expects property tests for pure/domain logic.'
    Write-Host "  Add FsCheck properties tagged [Trait(`"Category`",`"$Category`")], or set"
    Write-Host '  gates.propertyTests.enabled: false in harness.yml to opt out deliberately.'
    exit 2
}
finally {
    Pop-Location
}
