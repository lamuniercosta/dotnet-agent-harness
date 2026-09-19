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

# Tier-policy findings are advisory: printed, never fatal (2026-09-16).
Write-SeatMapWarnings -Warnings @(Get-SeatMapWarnings -Map $seatMap)

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

# 10. Duplicate pool violation across declared rungs when distinctPoolsPerSeat=true.
# The fixture opts the rule in itself: the example map now ships distinctPoolsPerSeat=false
# so an operator can stack several models from one pool on a seat.
Test-NegativeFixture -Name "duplicate pool violation" -Mutator { param($m) $m.invariants.distinctPoolsPerSeat = $true; $m.seats[0].rungs[1].pool = $m.seats[0].rungs[0].pool } -ExpectedErrorSubstring "does not have distinct pools"

# 11. OpenCode launch line missing -m/--model
Test-NegativeFixture -Name "opencode launch missing model flag" -Mutator { param($m) $m.seats[0].rungs[1].host = "opencode"; $m.seats[0].rungs[1].launch = "opencode run" } -ExpectedErrorSubstring "is missing -m/--model"

# 12. Numeric schemaVersion 2.5 negative validation
Test-NegativeFixture -Name "numeric schemaVersion 2.5" -Mutator { param($m) $m.schemaVersion = 2.5 } -ExpectedErrorSubstring "Seat map schemaVersion must be the integer 2 (got 2.5); schemaVersion 1 maps fail closed and in-place migration is not implemented."

# 13. Unknown host
Test-NegativeFixture -Name "unknown host" -Mutator { param($m) $m.seats[0].rungs[0].host = "unknown-host-xyz" } -ExpectedErrorSubstring "has unknown host"

# 14. Unknown pool
Test-NegativeFixture -Name "unknown pool" -Mutator { param($m) $m.seats[0].rungs[0].pool = "UNKNOWN_POOL" } -ExpectedErrorSubstring "has unknown pool"

# 15. Invalid evidence
Test-NegativeFixture -Name "invalid evidence" -Mutator { param($m) $m.seats[0].rungs[0].evidence = "bogus-evidence" } -ExpectedErrorSubstring "has unknown evidence"

# 16. Missing model
Test-NegativeFixture -Name "missing model" -Mutator { param($m) $m.seats[0].rungs[0].psobject.properties.remove('model') } -ExpectedErrorSubstring "missing model"

# --- Positive Fixtures: what the map is allowed to do ---
function Test-PositiveFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutator
    )
    $copy = ($seatMap | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    & $Mutator $copy
    $v = @(Get-SeatMapViolations -Map $copy)
    if ($v.Count -gt 0) {
        Write-Error "Positive fixture '$Name' unexpectedly FAILED validation: $($v -join "`n")" -ErrorAction Continue
        exit 1
    }
}

# P1. With distinctPoolsPerSeat=false, a seat may stack several models from one
# pool. This is the point of the flag: the operator adds every model they find
# fit as 'fourth', 'fifth', ... inserted before 'floor', regardless of pool.
Test-PositiveFixture -Name "extra rung reusing a pool before floor" -Mutator {
    param($m)
    $m.invariants.distinctPoolsPerSeat = $false
    $s = $m.seats[0]
    $extra = ($s.rungs[0] | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $extra.name = 'fourth'
    $extra.psobject.properties.remove('role')
    $s.rungs = @($s.rungs[0..($s.rungs.Count - 2)]) + @($extra) + @($s.rungs[-1])
}

# --- Warning Fixtures: tierPolicy must warn, and must not fail ---
function Test-WarningFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutator,
        [Parameter(Mandatory)][string]$ExpectedWarningSubstring
    )
    $json = $seatMap | ConvertTo-Json -Depth 100
    $copy = $json | ConvertFrom-Json
    & $Mutator $copy
    $v = @(Get-SeatMapViolations -Map $copy)
    if ($v.Count -gt 0) {
        Write-Error "Warning fixture '$Name' produced a hard violation; tier policy must stay advisory. Got: $($v -join '; ')" -ErrorAction Continue
        exit 1
    }
    $w = @(Get-SeatMapWarnings -Map $copy)
    $joined = $w -join "`n"
    if (-not $joined.Contains($ExpectedWarningSubstring)) {
        Write-Error "Warning fixture '$Name' did not warn. Expected substring: '$ExpectedWarningSubstring', Actual: '$joined'" -ErrorAction Continue
        exit 1
    }
}

if (Test-JsonProperty -Object $seatMap.invariants -Name 'tierPolicy') {
    # W1. Rung tier disagrees with the policy for its pool/model
    Test-WarningFixture -Name "tier mismatch" -Mutator { param($m) $m.seats[0].rungs[0].tier = 4 } -ExpectedWarningSubstring "TIER  Seat"
    # W2. A pool active on more seats than the operator caps it at (ZEN: 1)
    Test-WarningFixture -Name "zen on two active seats" -Mutator {
        param($m)
        foreach ($s in $m.seats) { foreach ($r in $s.rungs) { if ($r.pool -eq 'ZEN') { $s.activeRung = $r.name } } }
    } -ExpectedWarningSubstring "POOL  ZEN is the active rung on"
    # W3. A model outside the pool's reserved list (CLAUDE -> haiku only)
    Test-WarningFixture -Name "opus on the claude pool" -Mutator {
        param($m)
        $m.seats[0].rungs[1].pool = 'CLAUDE'; $m.seats[0].rungs[1].host = 'claude'
        $m.seats[0].rungs[1].model = 'claude-opus-4-6'; $m.seats[0].rungs[1].launch = 'claude --model claude-opus-4-6'
    } -ExpectedWarningSubstring "MODEL Seat"
    # W4. A pool the operator keeps off a seat (ZEN on Rigger); the mutation keeps pools distinct
    Test-WarningFixture -Name "zen on rigger" -Mutator {
        param($m)
        $rig = $m.seats | Where-Object { $_.id -eq 'rigger' } | Select-Object -First 1
        foreach ($r in $rig.rungs) {
            if ($r.pool -eq 'ZEN') { $r.pool = 'JETBRAINS'; $r.host = 'junie'; $r.model = 'gemini-3.1-flash-lite'; $r.launch = 'junie --model gemini-3.1-flash-lite' }
        }
        $rig.rungs[2].pool = 'ZEN'; $rig.rungs[2].host = 'opencode'
        $rig.rungs[2].model = 'opencode/muse-spark-1.3-contributor-free'; $rig.rungs[2].launch = 'opencode --model opencode/muse-spark-1.3-contributor-free --auto'
    } -ExpectedWarningSubstring "SEAT  Seat 'Rigger'"
    # W5. Rungs out of consumption order
    Test-WarningFixture -Name "chain out of consumption order" -Mutator { param($m) $m.seats[0].rungs[0].tier = 4; $m.seats[0].rungs[1].tier = 1 } -ExpectedWarningSubstring "ORDER Seat"
    Write-Host "Test-SeatMap: 5 warning fixtures verified (advisory, non-fatal)." -ForegroundColor Green
}

Write-Host "Test-SeatMap: All checks PASSED ($($seatMap.seats.Count) seats, schema valid, invariants held, 16 negative and 1 positive fixture verified)." -ForegroundColor Green
exit 0
