<#
.SYNOPSIS
    Pester / CI test for seat-map.json schema and charter invariants.
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
$failures = @(Get-SeatMapViolations -Map $seatMap)

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Host "Test-SeatMap: All checks PASSED ($($seatMap.seats.Count) seats, schema valid, charter invariants held)." -ForegroundColor Green
exit 0
