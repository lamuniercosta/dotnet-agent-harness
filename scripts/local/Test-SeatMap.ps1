<#
.SYNOPSIS
    Pester / CI test for seat-map.json schema and charter invariants.
#>
[CmdletBinding()]
param(
    [string]$SeatMapPath = "$PSScriptRoot/seat-map.json"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SeatMapPath)) {
    throw "Seat map file not found: $SeatMapPath"
}

$seatMap = Get-Content $SeatMapPath -Raw | ConvertFrom-Json

$knownHosts = @('claude', 'cursor', 'agy', 'junie', 'gemini', 'opencode', 'codex')
$validEvidence = @('measured', 'cleared', 'probed', 'unmeasured')
$validPools = @('CLAUDE', 'CODEX', 'CURSOR', 'AGY-G', 'AGY-C', 'JETBRAINS', 'GEMINI', 'OPENROUTER', 'ZEN')
$validCostSources = @('actual', 'estimated', 'unknown')

# Data-driven invariants from seat-map.json
$invariants = $seatMap.invariants
$maxCursorHeads = if ($null -ne $invariants -and $null -ne $invariants.maxCursorHeads) { [int]$invariants.maxCursorHeads } else { 2 }
$maxAgyGHeads = if ($null -ne $invariants -and $null -ne $invariants.maxAgyGHeads) { [int]$invariants.maxAgyGHeads } else { 1 }
$minGeminiHeads = if ($null -ne $invariants -and $null -ne $invariants.minGeminiHeads) { [int]$invariants.minGeminiHeads } else { 1 }
$disallowedFloorPools = if ($null -ne $invariants -and $null -ne $invariants.disallowedFloorPools) { @($invariants.disallowedFloorPools) } else { @('ZEN') }
$zenFloorExceptions = if ($null -ne $invariants -and $null -ne $invariants.zenFloorExceptions) { @($invariants.zenFloorExceptions) } else { @('Quill') }

$failures = @()

$cursorHeads = 0
$agyGHeads = 0
$geminiHeads = 0

foreach ($seat in $seatMap.seats) {
    # Check 3 rungs exist
    $rungs = @('head', 'then', 'floor')
    foreach ($r in $rungs) {
        $cell = $seat.rungs.$r
        if (-not $cell) {
            $failures += "Seat '$($seat.codename)' is missing '$r' rung."
            continue
        }

        if (-not $cell.launch) {
            $failures += "Seat '$($seat.codename)' rung '$r' missing launch line."
        }

        if ($validPools -notcontains $cell.pool) {
            $failures += "Seat '$($seat.codename)' rung '$r' has unknown pool '$($cell.pool)'."
        }

        if ($validEvidence -notcontains $cell.evidence) {
            $failures += "Seat '$($seat.codename)' rung '$r' has unknown evidence '$($cell.evidence)'."
        }

        if ($null -ne $cell.host -and $cell.host -ne '' -and $knownHosts -notcontains $cell.host) {
            $failures += "Seat '$($seat.codename)' rung '$r' has unknown host '$($cell.host)'."
        }

        if ($null -ne $cell.PSObject.Properties['evidenceDate'] -and $null -ne $cell.evidenceDate -and [string]$cell.evidenceDate -ne '') {
            if ([string]$cell.evidenceDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
                $failures += "Seat '$($seat.codename)' rung '$r' has invalid evidenceDate format '$($cell.evidenceDate)' (expected YYYY-MM-DD)."
            }
        }

        if ($null -ne $cell.PSObject.Properties['cost'] -and $null -ne $cell.cost) {
            $costSource = $cell.cost.source
            if (-not $costSource -or $validCostSources -notcontains $costSource) {
                $failures += "Seat '$($seat.codename)' rung '$r' has invalid cost.source '$costSource' (expected actual|estimated|unknown)."
            }
            if ($null -ne $cell.cost.PSObject.Properties['usd'] -and $null -ne $cell.cost.usd) {
                if (-not ($cell.cost.usd -is [int] -or $cell.cost.usd -is [double] -or $cell.cost.usd -is [decimal])) {
                    $failures += "Seat '$($seat.codename)' rung '$r' has non-numeric cost.usd '$($cell.cost.usd)'."
                }
            }
        }
    }

    # Head pool tallies
    if ($seat.rungs.head.pool -eq 'CURSOR') { $cursorHeads++ }
    if ($seat.rungs.head.pool -eq 'AGY-G') { $agyGHeads++ }
    if ($seat.rungs.head.pool -eq 'GEMINI') { $geminiHeads++ }

    # Floor pool rule checking disallowed floor pools with exceptions
    if ($disallowedFloorPools -contains $seat.rungs.floor.pool -and $zenFloorExceptions -notcontains $seat.codename -and $zenFloorExceptions -notcontains $seat.id) {
        $failures += "Seat '$($seat.codename)' has $($seat.rungs.floor.pool) on floor."
    }
}

if ($cursorHeads -gt $maxCursorHeads) {
    $failures += "At most $maxCursorHeads Cursor heads allowed (found $cursorHeads)."
}
if ($agyGHeads -gt $maxAgyGHeads) {
    $failures += "At most $maxAgyGHeads AGY-G heads allowed (found $agyGHeads)."
}
if ($geminiHeads -lt $minGeminiHeads) {
    $failures += "At least $minGeminiHeads Gemini heads required (found $geminiHeads)."
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
} else {
    Write-Host "Test-SeatMap: All checks PASSED ($($seatMap.seats.Count) seats, schema valid, charter invariants held)." -ForegroundColor Green
    exit 0
}
