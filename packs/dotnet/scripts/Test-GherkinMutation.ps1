#!/usr/bin/env pwsh
# Self-test for the Gherkin mutation gate's pure logic.
#
# Canned .feature content only - no Reqnroll, no build. The cases asserted are
# the ones that actually broke: the reassembly sliced 0..(Start-1) and
# (End+1)..(Count-1) inline, so a scenario ending at EOF threw (the slice
# became a descending range) and a scenario at line 0 silently duplicated the
# file's last line. The gate had never run against a real feature file, which
# is how both shipped. Run directly, or from CI via lint-harness.yml.
#
#   pwsh ./packs/dotnet/scripts/Test-GherkinMutation.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gherkin-mutation-lib.ps1')

$failures = 0
$checks = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $script:checks++
    if ($Expected -eq $Actual) {
        Write-Host "  ok    $Name = $Actual"
    }
    else {
        Write-Host "  FAIL  $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red
        $script:failures++
    }
}

function Assert-Reassembly {
    <#
      The mutated file must have the SAME line count as the original, with only
      the first Then line of the mutated scenario differing. Anything else - a
      dropped line, a duplicated line, a thrown index - means the gate mutates
      a file that is not the one it read.
    #>
    param(
        [string]$Name,
        [string[]]$Lines,
        [int]$Start,
        [int]$End,
        [int]$ExpectedDiffIndex
    )

    $script:checks++
    $scenario = $Lines[$Start..$End]
    $mutatedScenario = Get-MutatedLines -Lines $scenario

    $result = $null
    $threw = $null
    try {
        $result = Get-MutatedFileLines -Lines $Lines -Start $Start -End $End -MutatedScenario $mutatedScenario
    }
    catch {
        $threw = ($_.Exception.Message -split "`n")[0]
    }

    if ($threw) {
        Write-Host "  FAIL  $Name - reassembly threw: $threw" -ForegroundColor Red
        $script:failures++
        return
    }

    $result = @($result)

    if ($result.Count -ne $Lines.Count) {
        Write-Host "  FAIL  $Name - line count $($result.Count), expected $($Lines.Count)" -ForegroundColor Red
        $script:failures++
        return
    }

    $diffAt = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($result[$i] -ne $Lines[$i]) { $diffAt += $i }
    }

    if ($diffAt.Count -eq 1 -and $diffAt[0] -eq $ExpectedDiffIndex -and
        $result[$ExpectedDiffIndex] -eq '    Then the mutation sentinel expectation must fail') {
        Write-Host "  ok    $Name - only line $ExpectedDiffIndex mutated, count preserved"
    }
    else {
        Write-Host ("  FAIL  $Name - differences at [{0}], expected only line {1}" -f ($diffAt -join ', '), $ExpectedDiffIndex) -ForegroundColor Red
        $script:failures++
    }
}

# Two scenarios; the second runs to EOF. The shape that crashed the gate.
$twoScenarios = @(
    'Feature: Discount threshold'
    ''
    'Scenario: At the threshold'
    '    Given a shopping total of 100'
    '    When the discount is applied'
    '    Then the charged total should be 90'
    ''
    'Scenario: Below the threshold'
    '    Given a shopping total of 99.99'
    '    When the discount is applied'
    '    Then the charged total should be 99.99'
)

# One scenario spanning the whole file: Start = 0 AND End = Count - 1, both
# broken slice ends in a single case.
$wholeFile = @(
    'Scenario: Only scenario'
    '    Given a shopping total of 100'
    '    Then the charged total should be 90'
)

Write-Host 'Scenario discovery:'
$ranges = @(Get-ScenarioLineRanges -Lines $twoScenarios)
Assert-Equal 'two-scenario range count' 2 $ranges.Count
Assert-Equal 'first scenario name'      'At the threshold' $ranges[0].Name
Assert-Equal 'first scenario start'     2 $ranges[0].Start
Assert-Equal 'first scenario end'       6 $ranges[0].End
Assert-Equal 'second scenario start'    7 $ranges[1].Start
Assert-Equal 'second scenario end'      10 $ranges[1].End

$wholeRange = @(Get-ScenarioLineRanges -Lines $wholeFile)
Assert-Equal 'whole-file range count'   1 $wholeRange.Count
Assert-Equal 'whole-file start'         0 $wholeRange[0].Start
Assert-Equal 'whole-file end'           2 $wholeRange[0].End

Write-Host ''
Write-Host 'Reassembly is bounds-safe and lossless:'
Assert-Reassembly -Name 'mid-file scenario'   -Lines $twoScenarios -Start 2 -End 6  -ExpectedDiffIndex 5
Assert-Reassembly -Name 'scenario ending at EOF' -Lines $twoScenarios -Start 7 -End 10 -ExpectedDiffIndex 10
Assert-Reassembly -Name 'scenario spanning whole file' -Lines $wholeFile -Start 0 -End 2 -ExpectedDiffIndex 2

Write-Host ''
Write-Host 'Mutation targets the first Then only:'
$noThen = Get-MutatedLines -Lines @('Scenario: No then', '    Given something')
Assert-Equal 'appends sentinel when no Then' 3 @($noThen).Count
$twoThens = Get-MutatedLines -Lines @(
    '    Then first expectation'
    '    Then second expectation'
)
Assert-Equal 'second Then untouched' '    Then second expectation' $twoThens[1]

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "All $checks checks passed." -ForegroundColor Green
exit 0
