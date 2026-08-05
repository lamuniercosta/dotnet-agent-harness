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

$target = Resolve-BuildTarget -RepoRoot $repoRoot -Explicit $Project

Push-Location $repoRoot
try {
    Write-Host "Property tests: running tests with Category=$Category..."
    $output = dotnet test $target --filter "Category=$Category" --verbosity minimal 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }

    # No property tests is SKIPPED (exit 2), never passed (exit 0).
    #
    # This used to exit 0, which meant a repo with zero property tests reported
    # "Property tests: passed" having verified nothing - the precise failure this
    # harness exists to prevent, sitting inside the harness itself.
    #
    # It then used to match the "no tests matched" line anywhere in the output,
    # which broke the moment a solution had a second test assembly: the assembly
    # without property tests prints that line while another runs them, and the
    # gate reported SKIPPED over a run that had verified plenty. Decide on the
    # number of tests actually executed instead - see Get-TestRunOutcome.
    $outcome = Get-TestRunOutcome -Output $output -ExitCode $exitCode

    if ($outcome.Outcome -eq 'NothingMatched') {
        if ($outcome.Skipped -gt 0) {
            # Tests exist and are tagged; they just never ran. Telling someone to
            # add property tests they already have sends them the wrong way.
            Write-Host "Property tests: SKIPPED - $($outcome.Skipped) test(s) matched but every one was skipped."
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

    # A no-match line explains an assembly with no matching tests. It does not
    # explain a failed run. With several test assemblies, one can report no match
    # while another crashes before producing any counts - output indistinguishable
    # from a clean skip except for the exit code. Reporting that as SKIPPED hides
    # a failure behind "nothing to verify".
    if ($outcome.Outcome -eq 'Inconclusive') {
        Write-Host "GATE COULD NOT RUN: no tests executed, but dotnet test exited $exitCode." -ForegroundColor Red
        Write-Host '  A "no test matches" message accounts for one assembly, not for the failure.'
        Write-Host '  Something failed before reporting results - a build error, a crashed test host,'
        Write-Host '  or an assembly that could not be discovered.'
        Write-Host "  Run it directly to see why: dotnet test $target --filter `"Category=$Category`""
        exit 1
    }

    # Zero tests executed and nothing saying why. Reporting that as either a pass
    # or a skip would be a guess about a run that produced no readable result, so
    # say so and stop.
    if ($outcome.Outcome -eq 'Unknown') {
        Write-Host 'GATE COULD NOT RUN: dotnet test reported no executed tests and no reason.' -ForegroundColor Red
        Write-Host '  Neither a test-count summary nor a "no test matches" message was found.'
        Write-Host "  Run it directly to see why: dotnet test $target --filter `"Category=$Category`""
        exit 1
    }

    if ($exitCode -ne 0) {
        Write-Host "Property tests: FAILED ($($outcome.Executed) test(s) executed)."
        exit 1
    }

    Write-Host "Property tests: passed ($($outcome.Executed) test(s) executed)."
    exit 0
}
finally {
    Pop-Location
}
