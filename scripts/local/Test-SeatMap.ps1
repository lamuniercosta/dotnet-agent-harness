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

# --- Negative Fixtures Verification (DEV-235 B6) ---
function Test-NegativeFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutator,
        [Parameter(Mandatory)][string]$ExpectedErrorSubstring
    )
    # Deep copy seatMap via Json round-trip
    $json = $seatMap | ConvertTo-Json -Depth 100
    $copy = $json | ConvertFrom-Json
    & $Mutator $copy
    $v = @(Get-SeatMapViolations -Map $copy)
    if ($v.Count -eq 0) {
        Write-Error "Negative fixture '$Name' unexpectedly PASSED validation (expected error containing '$ExpectedErrorSubstring')." -ErrorAction Continue
        exit 1
    }
    $joined = $v -join "`n"
    if (-not $joined.Contains($ExpectedErrorSubstring)) {
        Write-Error "Negative fixture '$Name' failed with unexpected error. Expected substring: '$ExpectedErrorSubstring', Actual: '$joined'" -ErrorAction Continue
        exit 1
    }
}

# 1. SchemaVersion 1 fail-closed
Test-NegativeFixture -Name "schemaVersion 1 fail-closed" -Mutator { param($m) $m.schemaVersion = 1 } -ExpectedErrorSubstring "schemaVersion 1 is not supported"

# 2. Short rungs array (< 4 rungs)
Test-NegativeFixture -Name "short rungs array" -Mutator { param($m) $m.seats[0].rungs = @($m.seats[0].rungs[0..2]) } -ExpectedErrorSubstring "rungs array is short"

# 3. Duplicate rung name in same seat
Test-NegativeFixture -Name "duplicate rung name" -Mutator { param($m) $m.seats[0].rungs[1].name = $m.seats[0].rungs[0].name } -ExpectedErrorSubstring "duplicate rung name"

# 4. Unsafe rung name (violates ^[a-z][a-z0-9-]{0,30}$)
Test-NegativeFixture -Name "unsafe rung name" -Mutator { param($m) $m.seats[0].rungs[1].name = "INVALID_NAME!" } -ExpectedErrorSubstring "is unsafe"

# 5. Missing activeRung target
Test-NegativeFixture -Name "missing activeRung target" -Mutator { param($m) $m.seats[0].activeRung = "nonexistent-rung" } -ExpectedErrorSubstring "does not match a declared rung name"

# 6. Missing head role
Test-NegativeFixture -Name "missing head role" -Mutator { param($m) $m.seats[0].rungs[0].psobject.properties.remove('role') } -ExpectedErrorSubstring "missing a rung with role 'head'"

# 7. Head role not first element
Test-NegativeFixture -Name "head role not first" -Mutator { param($m) $m.seats[0].rungs[0].psobject.properties.remove('role'); Add-Member -InputObject $m.seats[0].rungs[1] -NotePropertyName "role" -NotePropertyValue "head" -Force } -ExpectedErrorSubstring "must be the first rung"

# 8. Missing floor role
Test-NegativeFixture -Name "missing floor role" -Mutator { param($m) $m.seats[0].rungs[3].psobject.properties.remove('role') } -ExpectedErrorSubstring "missing a rung with role 'floor'"

# 9. Floor role not last element
Test-NegativeFixture -Name "floor role not last" -Mutator { param($m) $m.seats[0].rungs[3].psobject.properties.remove('role'); Add-Member -InputObject $m.seats[0].rungs[2] -NotePropertyName "role" -NotePropertyValue "floor" -Force } -ExpectedErrorSubstring "must be the last rung"

# 10. Duplicate pool violation across declared rungs when distinctPoolsPerSeat=true
Test-NegativeFixture -Name "duplicate pool violation" -Mutator { param($m) $m.seats[0].rungs[1].pool = $m.seats[0].rungs[0].pool } -ExpectedErrorSubstring "does not have distinct pools"

# 11. OpenCode launch line missing -m/--model
Test-NegativeFixture -Name "opencode launch missing model flag" -Mutator { param($m) $m.seats[0].rungs[1].host = "opencode"; $m.seats[0].rungs[1].launch = "opencode run" } -ExpectedErrorSubstring "is missing -m/--model"

# 12. Numeric schemaVersion 2.5 negative validation
Test-NegativeFixture -Name "numeric schemaVersion 2.5" -Mutator { param($m) $m.schemaVersion = 2.5 } -ExpectedErrorSubstring "Seat map schemaVersion must be the integer 2 (got 2.5); schemaVersion 1 maps fail closed and in-place migration is not implemented."

Write-Host "Test-SeatMap: All checks PASSED ($($seatMap.seats.Count) seats, schema valid, invariants held, 12 negative fixtures verified)." -ForegroundColor Green
exit 0
