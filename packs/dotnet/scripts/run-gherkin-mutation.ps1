#!/usr/bin/env pwsh
# Mutates Then clauses in acceptance .feature files and verifies Reqnroll tests fail.
# Exits 1 when mutation survivors are found (tests still pass after mutation); exits 0 when all killed.

[CmdletBinding()]
param(
    [string]$Project = '',
    [string]$SpecsPath = 'specs',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @"
Usage: run-gherkin-mutation.ps1 [OPTIONS]

For each scenario in <SpecsPath>/**/*.feature, temporarily mutates the first
Then step, runs acceptance tests, and restores the file. Tests MUST fail after mutation.

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

function Get-ScenarioLineRanges {
    param([string[]]$Lines)

    $ranges = @()
    $start = -1
    $name = ''

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]

        if ($line -match '^\s*Scenario(?:\s+Outline)?:\s*(.+)') {
            if ($start -ge 0) {
                $ranges += [PSCustomObject]@{ Name = $name; Start = $start; End = $i - 1 }
            }

            $name = $Matches[1].Trim()
            $start = $i
        }
    }

    if ($start -ge 0) {
        $ranges += [PSCustomObject]@{ Name = $name; Start = $start; End = $Lines.Count - 1 }
    }

    return $ranges
}

function Get-MutatedLines {
    param([string[]]$Lines)

    $result = @()
    $mutatedThen = $false

    foreach ($line in $Lines) {
        if (-not $mutatedThen -and $line -match '^\s*Then\s+') {
            $result += '    Then the mutation sentinel expectation must fail'
            $mutatedThen = $true
        }
        else {
            $result += $line
        }
    }

    if (-not $mutatedThen) {
        $result += '    Then the mutation sentinel expectation must fail'
    }

    return $result
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
}
finally {
    Pop-Location
}

$survivors = @()

foreach ($featureFile in $featureFiles) {
    $originalLines = @(Get-Content -Path $featureFile.FullName)
    $ranges = Get-ScenarioLineRanges -Lines $originalLines

    foreach ($range in $ranges) {
        $scenarioLines = $originalLines[$range.Start..$range.End]
        $mutatedScenario = Get-MutatedLines -Lines $scenarioLines
        $mutatedFile = @($originalLines[0..($range.Start - 1)] + $mutatedScenario + $originalLines[($range.End + 1)..($originalLines.Count - 1)])

        $backupPath = "$($featureFile.FullName).mutation.bak"
        Copy-Item -Path $featureFile.FullName -Destination $backupPath -Force

        try {
            Set-Content -Path $featureFile.FullName -Value $mutatedFile -Encoding UTF8

            $relativeFeature = $featureFile.FullName.Replace($repoRoot, '').TrimStart('\', '/')
            Write-Host "Gherkin mutation: mutating '$($range.Name)' in $relativeFeature..."

            Push-Location $repoRoot
            try {
                dotnet test $acceptanceProject --no-build --verbosity quiet --filter "DisplayName~$($range.Name)" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $survivors += [PSCustomObject]@{
                        Feature  = $relativeFeature
                        Scenario = $range.Name
                    }
                }
            }
            finally {
                Pop-Location
            }
        }
        finally {
            Move-Item -Path $backupPath -Destination $featureFile.FullName -Force
        }
    }
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
