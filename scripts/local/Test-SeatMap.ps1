<#
.SYNOPSIS
    Pester / CI test for seat-map schema and its declared invariants.
.PARAMETER SeatMapPath
    Path to a seat map. Empty (default) resolves the live workspace path
    lazily after helpers are loaded. CI passes scripts/local/seat-map.example.json.
.PARAMETER WorkspaceId
    Maestri workspace UUID. Passed to live-path resolution; explicit -SeatMapPath
    still overrides discovery.
#>
[CmdletBinding()]
param(
    [string]$SeatMapPath,
    [string]$WorkspaceId
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_seat-map.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
$resolvedMap = Resolve-LiveSeatMapPath -SeatMapPath $SeatMapPath -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
$SeatMapPath = $resolvedMap.Path
if (-not $resolvedMap.Ok) {
    Write-SeatMapResolutionFailureMessage -ResolverError ([string]$resolvedMap.Error)
    exit 1
}
if (-not (Test-Path -LiteralPath $SeatMapPath)) {
    Write-SeatMapMissingMessage -Path $SeatMapPath
    exit 1
}

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
