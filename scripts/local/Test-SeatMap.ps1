<#
.SYNOPSIS
    Pester / CI test for seat-map.json schema and its declared invariants.
#>
[CmdletBinding()]
param(
    [string]$SeatMapPath = (Join-Path $PSScriptRoot 'seat-map.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SeatMapPath)) {
    throw "Seat map file not found: $SeatMapPath"
}

. (Join-Path $PSScriptRoot '_seat-map.ps1')

$seatMap = Get-Content -LiteralPath $SeatMapPath -Raw | ConvertFrom-Json

# Policy lives in the map's own invariants block; Get-SeatMapViolations
# enforces it. Quota changes are map edits, not test edits (2026-09-15).
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($v in @(Get-SeatMapViolations -Map $seatMap)) {
    $failures.Add($v)
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Host "Test-SeatMap: All checks PASSED ($($seatMap.seats.Count) seats, schema valid, invariants held)." -ForegroundColor Green
exit 0
