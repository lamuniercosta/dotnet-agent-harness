#!/usr/bin/env pwsh
# Pure functions for run-gherkin-mutation.ps1, extracted so Test-GherkinMutation.ps1
# can exercise them without a Reqnroll project or a build.
# Dot-source after _gate-common.ps1:  . (Join-Path $PSScriptRoot '_gherkin-mutation-lib.ps1')

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

function Get-MutatedFileLines {
    <#
      Both slice ends need guarding: 0..-1 is @(0, -1) (first AND last element,
      not an empty slice) and (Count)..(Count-1) is a descending range whose
      first index is out of bounds. A scenario at line 0 or ending at EOF hits
      one each - i.e. the last scenario of every feature file.
    #>
    param(
        [string[]]$Lines,
        [int]$Start,
        [int]$End,
        [string[]]$MutatedScenario
    )

    $head = @()
    if ($Start -gt 0) {
        $head = @($Lines[0..($Start - 1)])
    }

    $tail = @()
    if ($End -lt $Lines.Count - 1) {
        $tail = @($Lines[($End + 1)..($Lines.Count - 1)])
    }

    return @($head + $MutatedScenario + $tail)
}
