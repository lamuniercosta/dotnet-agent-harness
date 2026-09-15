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

# PF1: charter policy is pinned here, not taken from the JSON under test.
# 2026-09-15: Cursor and AGY-G head quotas raised from 2/1 to 3/3 (operator decision; Anvil, Gauge and Rigger head on Cursor, Cog and Compass on AGY-G).
# The invariants block stays informational; editing its thresholds must not
# green the gate.
$failures = [System.Collections.Generic.List[string]]::new()
$inv = $null
if (Test-JsonProperty -Object $seatMap -Name 'invariants') { $inv = $seatMap.invariants }

function Get-InvariantValue {
    param($Object, [string]$Name)
    if (-not (Test-JsonProperty -Object $Object -Name $Name)) { return $null }
    return $Object.$Name
}

$maxCursor = Get-InvariantValue -Object $inv -Name 'maxCursorHeads'
$maxAgy = Get-InvariantValue -Object $inv -Name 'maxAgyGHeads'
$minGemini = Get-InvariantValue -Object $inv -Name 'minGeminiHeads'
$floorPools = @(Get-InvariantValue -Object $inv -Name 'disallowedFloorPools')
$distinct = Get-InvariantValue -Object $inv -Name 'distinctPoolsPerSeat'
$zenExRaw = Get-InvariantValue -Object $inv -Name 'zenFloorExceptions'
$zenEx = @()
if ($null -ne $zenExRaw) { $zenEx = @($zenExRaw) }

if ($null -eq $maxCursor -or [int]$maxCursor -ne 3) {
    $failures.Add("Charter policy pin: maxCursorHeads must be 3 (JSON has '$maxCursor').")
}
if ($null -eq $maxAgy -or [int]$maxAgy -ne 3) {
    $failures.Add("Charter policy pin: maxAgyGHeads must be 3 (JSON has '$maxAgy').")
}
if ($null -eq $minGemini -or [int]$minGemini -ne 1) {
    $failures.Add("Charter policy pin: minGeminiHeads must be 1 (JSON has '$minGemini').")
}
if ($floorPools -notcontains 'ZEN') {
    $failures.Add("Charter policy pin: disallowedFloorPools must contain ZEN (JSON has '$($floorPools -join ', ')').")
}
if ($null -eq $distinct -or [bool]$distinct -ne $true) {
    $failures.Add("Charter policy pin: distinctPoolsPerSeat must be true (JSON has '$distinct').")
}
if ($zenEx.Count -ne 1 -or [string]$zenEx[0] -ne 'Quill') {
    $failures.Add("Charter policy pin: zenFloorExceptions must be exactly Quill (JSON has '$($zenEx -join ', ')').")
}

foreach ($v in @(Get-SeatMapViolations -Map $seatMap)) {
    $failures.Add($v)
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Host "Test-SeatMap: All checks PASSED ($($seatMap.seats.Count) seats, schema valid, charter invariants held)." -ForegroundColor Green
exit 0
