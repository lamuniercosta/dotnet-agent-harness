#!/usr/bin/env pwsh
# Mutates Then clauses in acceptance .feature files and verifies Reqnroll tests fail.
# Exits 1 when mutation survivors are found (tests still pass after mutation); exits 0 when all killed.
#
# "Killed" is only meaningful against a baseline: every scenario is first run
# UNMUTATED and must pass, because a scenario that fails anyway - or a filter
# that matched zero tests - makes the mutated run's failure uninformative.
# Reqnroll compiles .feature files into code-behind at build time, so the
# mutated run rebuilds before testing; without that rebuild the mutation never
# executes and every mutant "survives".

[CmdletBinding()]
param(
    [string]$Project = '',
    [string]$SpecsPath = 'specs',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_gate-common.ps1')
. (Join-Path $PSScriptRoot '_gherkin-mutation-lib.ps1')

if ($Help) {
    Write-Output @"
Usage: run-gherkin-mutation.ps1 [OPTIONS]

For each scenario in <SpecsPath>/**/*.feature: run it unmutated (baseline must
pass), then temporarily mutate the first Then step, rebuild, and re-run. Tests
MUST fail after mutation.

OPTIONS:
  -Project <path>     Acceptance test project (default: auto-discovered by name)
  -SpecsPath <dir>    Directory to scan for .feature files (default: specs)
  -Help               Show this help

EXAMPLES:
  ./scripts/run-gherkin-mutation.ps1
  ./scripts/run-gherkin-mutation.ps1 -Project tests/My.AcceptanceTests/My.AcceptanceTests.csproj
"@
    exit 0
}

$repoRoot = Get-RepoRoot
$acceptanceProject = Resolve-TestProject -RepoRoot $repoRoot -Explicit $Project -NamePatterns @('*AcceptanceTests', '*.Acceptance', '*AcceptanceTest')

$featureFiles = @(Get-ChildItem -Path (Join-Path $repoRoot $SpecsPath) -Recurse -Filter '*.feature' -ErrorAction SilentlyContinue)

if ($featureFiles.Count -eq 0) {
    # SKIPPED (exit 2), not passed (exit 0). Acceptance tests are opt-in, so
    # having none is legitimate - but "not applicable" and "verified clean" are
    # different results, and collapsing them into exit 0 would let this gate
    # report success having examined nothing.
    Write-Host "Gherkin mutation: SKIPPED - no .feature files under $SpecsPath/."
    Write-Host '  Acceptance tests are opt-in; this is expected unless the repo has adopted them.'
    exit 2
}

# Feature files exist but there is no project to run them: that is a real gap,
# not a clean pass. Fail rather than reporting a vacuous success.
if (-not $acceptanceProject) {
    Write-Host "Gherkin mutation: FAILED - found $($featureFiles.Count) .feature file(s) but no acceptance test project."
    Write-Host '  The scenarios are unverified. Create an acceptance test project, or pass -Project <path>.'
    exit 1
}

Write-Host 'Gherkin mutation: building acceptance tests...'
Push-Location $repoRoot
try {
    dotnet build $acceptanceProject --verbosity quiet | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Gherkin mutation: build failed.'
        exit 1
    }

    $scenarios = @()
    foreach ($featureFile in $featureFiles) {
        $lines = @(Get-Content -Path $featureFile.FullName)
        foreach ($range in @(Get-ScenarioLineRanges -Lines $lines)) {
            $scenarios += [PSCustomObject]@{
                File  = $featureFile
                Lines = $lines
                Name  = $range.Name
                Start = $range.Start
                End   = $range.End
            }
        }
    }

    # Baseline first, per scenario. Non-zero from `dotnet test` can mean the
    # filter matched nothing rather than a failing test, and on some SDKs a
    # zero-match run exits 0 - so the message is checked on both paths, the
    # same trap run-property-tests.ps1 documents. Either way the gate cannot
    # conclude anything: say so and exit 1 rather than reporting a pass it did
    # not earn.
    foreach ($s in $scenarios) {
        $baseline = dotnet test $acceptanceProject --no-build --verbosity quiet --filter "DisplayName~$($s.Name)" 2>&1 | ForEach-Object { $_.ToString() }
        $noMatch = @($baseline | Where-Object { $_ -match 'No test matches the given testcase filter' })
        if ($LASTEXITCODE -ne 0 -or $noMatch.Count -gt 0) {
            Write-Host "Gherkin mutation: GATE COULD NOT RUN - baseline for scenario '$($s.Name)' did not pass unmutated."
            Write-Host '  A scenario that fails before mutation - or a filter matching no test - makes the mutated run uninformative.'
            Write-Host '  Fix the scenario or the DisplayName filter first; the gate asserts kills against a green baseline only.'
            exit 1
        }
    }

    $survivors = @()

    foreach ($s in $scenarios) {
        $mutatedScenario = Get-MutatedLines -Lines $s.Lines[$s.Start..$s.End]
        $mutatedFile = Get-MutatedFileLines -Lines $s.Lines -Start $s.Start -End $s.End -MutatedScenario $mutatedScenario

        $backupPath = "$($s.File.FullName).mutation.bak"
        Copy-Item -Path $s.File.FullName -Destination $backupPath -Force

        try {
            Set-Content -Path $s.File.FullName -Value $mutatedFile -Encoding UTF8

            $relativeFeature = $s.File.FullName.Replace($repoRoot, '').TrimStart('\', '/')
            Write-Host "Gherkin mutation: mutating '$($s.Name)' in $relativeFeature..."

            # The mutation only exists in the .feature file until it is
            # compiled into new code-behind. Testing without rebuilding was the
            # original bug: the mutated scenario still passed, because the
            # binary still held the unmutated scenario.
            dotnet build $acceptanceProject --verbosity quiet | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Gherkin mutation: GATE COULD NOT RUN - the rebuild after mutating '$($s.Name)' failed."
                Write-Host '  The sentinel step compiles in a healthy project; a build break here means the mutation machinery, not the tests.'
                exit 1
            }

            dotnet test $acceptanceProject --no-build --verbosity quiet --filter "DisplayName~$($s.Name)" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $survivors += [PSCustomObject]@{
                    Feature  = $relativeFeature
                    Scenario = $s.Name
                }
            }
        }
        finally {
            Move-Item -Path $backupPath -Destination $s.File.FullName -Force
            # The restore preserves the ORIGINAL timestamp, which is now older
            # than the code-behind generated from the mutated file - so an
            # up-to-date check would skip regeneration and leave the mutation
            # compiled into the binary. Touch it so the final rebuild below
            # actually regenerates.
            (Get-Item -LiteralPath $s.File.FullName).LastWriteTime = Get-Date
        }
    }

    # Every mutated run rebuilt the project, so the binary no longer matches
    # the restored sources. Leave the tree clean for whatever runs next.
    dotnet build $acceptanceProject --verbosity quiet | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Gherkin mutation: GATE COULD NOT RUN - the final rebuild after restoring the feature files failed.'
        exit 1
    }
}
finally {
    Pop-Location
}

if ($survivors.Count -gt 0) {
    Write-Host "Gherkin mutation: FAILED - $($survivors.Count) survivor(s):"
    foreach ($s in $survivors) {
        Write-Host "  $($s.Feature) :: $($s.Scenario)"
    }

    Write-Host ''
    Write-Host 'Survivors indicate tests still passed after Then mutation - the bindings do not actually assert the outcome.'
    exit 1
}

Write-Host 'Gherkin mutation: passed (no survivors).'
exit 0
