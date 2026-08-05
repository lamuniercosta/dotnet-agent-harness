#!/usr/bin/env pwsh
# Runs xUnit tests tagged with Category=Property (FsCheck property tests).
# Exits 1 when any property test fails; exits 0 when all pass or none found.
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
    $outcome = Get-TestRunOutcome -Output $output

    if ($outcome.Outcome -eq 'NothingMatched') {
        Write-Host "Property tests: SKIPPED - no tests tagged Category=$Category."
        Write-Host '  The refactor gate expects property tests for pure/domain logic.'
        Write-Host "  Add FsCheck properties tagged [Trait(`"Category`",`"$Category`")], or set"
        Write-Host '  gates.propertyTests.enabled: false in harness.yml to opt out deliberately.'
        exit 2
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
