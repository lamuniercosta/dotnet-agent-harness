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

Runs dotnet test with filter Category=Property, ONE TEST PROJECT AT A TIME.
Every discovered test project is covered without naming them.

Per project on purpose: a whole-solution run interleaves each assembly's
output, and the signals that classify a run are per assembly while the exit
code is not - which made "this assembly had no matching tests" and "that
assembly died before reporting" indistinguishable.

OPTIONS:
  -Project <path>   A single test .csproj (default: every discovered one).
                    A solution is rejected - omit -Project instead.
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
# @() at every assignment, not inside Get-TestProjects: PowerShell unwraps a
# one-element array on return, and `.Count` on the resulting string throws under
# Set-StrictMode. A repo with exactly one test project - the common shape - would
# crash before running anything, and the fixture's two projects hid it.
#                    vvv wraps the WHOLE conditional, not each branch: a branch
# emitting a one-element array still unwraps to a string on its way out of the
# if-expression, which is how this same trap survived being "fixed" once already.
$targets = @(if ($Project) {
    # A solution is rejected rather than silently reinterpreted. Expanding it to
    # every test project in the repo would run projects outside the named
    # solution, so a scoped request could fail on something it never asked about.
    if ($Project -match '\.slnx?$') {
        Write-Host 'GATE COULD NOT RUN: -Project takes a test project, not a solution.' -ForegroundColor Red
        Write-Host '  Name a .csproj to run one project, or omit -Project to run every'
        Write-Host '  discovered test project - each is run separately either way.'
        exit 1
    }
    Resolve-BuildTarget -RepoRoot $repoRoot -Explicit $Project
}
else {
    Get-TestProjects -RepoRoot $repoRoot
})

# No fallback to running the solution: that is the interleaved path this design
# exists to avoid, and it would be re-entered exactly when discovery is already
# known to be unreliable. Discovery reads each .csproj for the test SDK or
# IsTestProject, so a repo declaring either only in Directory.Build.props finds
# nothing - which is a configuration problem to report, not to paper over.
if ($targets.Count -eq 0) {
    Write-Host 'GATE COULD NOT RUN: no test projects found.' -ForegroundColor Red
    Write-Host '  Looked for .csproj files referencing Microsoft.NET.Test.Sdk or setting'
    Write-Host '  <IsTestProject>true</IsTestProject>. Both are inherited if they live only'
    Write-Host '  in Directory.Build.props, where this cannot see them.'
    Write-Host '  Fix: set <IsTestProject>true</IsTestProject> in each test .csproj, or pass'
    Write-Host '  -Project <path-to-test.csproj>.'
    exit 1
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
