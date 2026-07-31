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
    # harness exists to prevent, sitting inside the harness itself. `dotnet test`
    # also exits non-zero when a filter matches nothing on some SDKs, so the
    # "no tests matched" message is checked on both paths.
    if ($output -match 'No test matches the given testcase filter') {
        Write-Host "Property tests: SKIPPED - no tests tagged Category=$Category."
        Write-Host '  The refactor gate expects property tests for pure/domain logic.'
        Write-Host "  Add FsCheck properties tagged [Trait(`"Category`",`"$Category`")], or set"
        Write-Host '  gates.propertyTests.enabled: false in harness.yml to opt out deliberately.'
        exit 2
    }

    if ($exitCode -ne 0) {
        Write-Host 'Property tests: FAILED.'
        exit 1
    }

    Write-Host 'Property tests: passed.'
    exit 0
}
finally {
    Pop-Location
}
