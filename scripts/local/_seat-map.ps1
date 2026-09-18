# Shared seat-map helpers. Dot-sourced by Test-SeatMap, Sync-SeatMap,
# Start-SeatMapServer, and Test-ModelProbe so charter invariants (including the
# Quill ZEN-floor exception), advisory tier-policy warnings, target-swap
# runtime FLOOR selection, and the per-canonical-SeatMapPath process lock
# cannot drift between the CI gate, the synchronizer, the portal, and the
# probe writer.

. (Join-Path $PSScriptRoot '_json-property.ps1')

function Get-SeatMapRequiredSchemaVersion {
    return 2
}

function Get-SeatMapV1FailClosedDiagnostic {
    return 'Seat map schemaVersion 1 is not supported; schemaVersion 2 is required. In-place migration is not implemented.'
}

function Format-SeatMapSchemaVersionGot {
    param($Got)
    if ($null -eq $Got) { return '' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Got -is [double] -or $Got -is [float] -or $Got -is [single] -or $Got -is [decimal]) {
        return ([decimal]$Got).ToString($invariant)
    }
    return [string]$Got
}

function Test-SeatMapIsExactSchemaVersion2 {
    param($Raw)
    if ($null -eq $Raw) { return $false }
    # Integral CLR integer types only. Decimal/double 2.5 must not truncate to 2;
    # JSON 2.0 is also rejected so schemaVersion is an integer token, not a float.
    if ($Raw -is [byte] -or $Raw -is [sbyte] -or
        $Raw -is [int16] -or $Raw -is [uint16] -or
        $Raw -is [int] -or $Raw -is [uint32] -or
        $Raw -is [long] -or $Raw -is [uint64] -or
        $Raw -is [int64]) {
        return ([int64]$Raw -eq [int64]2)
    }
    return $false
}

function Test-SeatMapIsSchemaVersion1 {
    param($Raw)
    if ($null -eq $Raw) { return $false }
    if ($Raw -is [byte] -or $Raw -is [sbyte] -or
        $Raw -is [int16] -or $Raw -is [uint16] -or
        $Raw -is [int] -or $Raw -is [uint32] -or
        $Raw -is [long] -or $Raw -is [uint64] -or
        $Raw -is [int64]) {
        return ([int64]$Raw -eq [int64]1)
    }
    return ([string]$Raw -eq '1')
}

function Get-SeatMapSchemaVersionDiagnostic {
    param($Got)
    if (Test-SeatMapIsSchemaVersion1 -Raw $Got) {
        return Get-SeatMapV1FailClosedDiagnostic
    }
    $shown = Format-SeatMapSchemaVersionGot -Got $Got
    return "Seat map schemaVersion must be the integer 2 (got $shown); schemaVersion 1 maps fail closed and in-place migration is not implemented."
}

function ConvertTo-SeatMapQuotedArgument {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )
    if ($null -eq $Text) { $Text = '' }
    return "'" + $Text.Replace("'", "''") + "'"
}

function Get-SeatMapRecruitCommand {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Codename,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Preset,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Launch
    )
    $c = ConvertTo-SeatMapQuotedArgument -Text $Codename
    $p = ConvertTo-SeatMapQuotedArgument -Text $Preset
    $l = ConvertTo-SeatMapQuotedArgument -Text $Launch
    return "maestri recruit $c --preset $p --command $l --replace $c"
}

function Write-SeatMapViolationsAndExit {
    param([object[]]$Violations)
    if (@($Violations).Count -eq 0) { return }
    foreach ($v in @($Violations)) {
        [Console]::Error.WriteLine([string]$v)
    }
    exit 1
}

function Test-SeatMapRungName {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return [bool]($Name -cmatch '^[a-z][a-z0-9-]{0,30}$')
}

function Escape-SeatMapHtml {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-SeatMapRungList {
    param($Seat)
    if ($null -eq $Seat) { return $null }
    if (-not (Test-JsonProperty -Object $Seat -Name 'rungs')) { return $null }
    $rungs = $Seat.rungs
    if ($null -eq $rungs) { return $null }

    if ($rungs -is [string]) { return $null }

    if ($rungs -is [System.Collections.IList] -or $rungs -is [System.Array]) {
        return @($rungs)
    }

    # ConvertFrom-Json unwrap of a one-element array: a single rung object with name.
    if (($rungs -is [System.Management.Automation.PSCustomObject]) -and
        (Test-JsonProperty -Object $rungs -Name 'name') -and
        -not (Test-JsonProperty -Object $rungs -Name 'head')) {
        return @($rungs)
    }

    return $null
}

function Get-SeatMapRungByName {
    param(
        $Seat,
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $list = Get-SeatMapRungList -Seat $Seat
    if ($null -eq $list) { return $null }
    foreach ($cell in $list) {
        if ($null -eq $cell) { continue }
        $n = if (Test-JsonProperty -Object $cell -Name 'name') { [string]$cell.name } else { '' }
        if ($n -ceq $Name) { return $cell }
    }
    return $null
}

function Get-SeatMapRungByRole {
    param(
        $Seat,
        [string]$Role
    )
    if ([string]::IsNullOrWhiteSpace($Role)) { return $null }
    $list = Get-SeatMapRungList -Seat $Seat
    if ($null -eq $list) { return $null }
    foreach ($cell in $list) {
        if ($null -eq $cell) { continue }
        if ((Test-JsonProperty -Object $cell -Name 'role') -and ([string]$cell.role -ceq $Role)) {
            return $cell
        }
    }
    return $null
}

function Get-SeatMapActiveRungName {
    param($Seat)
    if ((Test-JsonProperty -Object $Seat -Name 'activeRung') -and -not [string]::IsNullOrWhiteSpace([string]$Seat.activeRung)) {
        return [string]$Seat.activeRung
    }
    $head = Get-SeatMapRungByRole -Seat $Seat -Role 'head'
    if ($null -ne $head -and (Test-JsonProperty -Object $head -Name 'name')) {
        return [string]$head.name
    }
    return ''
}

function Find-SeatMapSeat {
    param(
        $Map,
        [string]$Name
    )
    if ($null -eq $Map -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    if (-not (Test-JsonProperty -Object $Map -Name 'seats')) { return $null }
    foreach ($s in @($Map.seats)) {
        $id = if (Test-JsonProperty -Object $s -Name 'id') { [string]$s.id } else { '' }
        $code = if (Test-JsonProperty -Object $s -Name 'codename') { [string]$s.codename } else { '' }
        $seatName = if (Test-JsonProperty -Object $s -Name 'name') { [string]$s.name } else { '' }
        if ($id -eq $Name -or $code -eq $Name -or $seatName -eq $Name) {
            return $s
        }
    }
    return $null
}

function Get-SeatMapViolations {
    param(
        [Parameter(Mandatory = $true)]
        $Map
    )

    $knownHosts = @('claude', 'cursor', 'agy', 'junie', 'gemini', 'opencode', 'codex')
    $validEvidence = @('measured', 'cleared', 'probed', 'unmeasured')
    $validPools = @('CLAUDE', 'CODEX', 'CURSOR', 'AGY-G', 'AGY-C', 'JETBRAINS', 'GEMINI', 'OPENROUTER', 'DEEPSEEK', 'ZEN')
    $validCostSources = @('actual', 'estimated', 'unknown')
    $validRoles = @('head', 'floor')

    $invariants = $null
    if (Test-JsonProperty -Object $Map -Name 'invariants') {
        $invariants = $Map.invariants
    }

    $maxCursorHeads = 3
    $maxAgyGHeads = 3
    $minGeminiHeads = 1
    $disallowedFloorPools = @('ZEN')
    $zenFloorExceptions = @('Quill')
    $distinctPoolsPerSeat = $true

    if (Test-JsonProperty -Object $invariants -Name 'maxCursorHeads') { $maxCursorHeads = [int]$invariants.maxCursorHeads }
    if (Test-JsonProperty -Object $invariants -Name 'maxAgyGHeads') { $maxAgyGHeads = [int]$invariants.maxAgyGHeads }
    if (Test-JsonProperty -Object $invariants -Name 'minGeminiHeads') { $minGeminiHeads = [int]$invariants.minGeminiHeads }
    if (Test-JsonProperty -Object $invariants -Name 'disallowedFloorPools') { $disallowedFloorPools = @($invariants.disallowedFloorPools) }
    if (Test-JsonProperty -Object $invariants -Name 'zenFloorExceptions') { $zenFloorExceptions = @($invariants.zenFloorExceptions) }
    if (Test-JsonProperty -Object $invariants -Name 'distinctPoolsPerSeat') { $distinctPoolsPerSeat = [bool]$invariants.distinctPoolsPerSeat }

    $failures = [System.Collections.Generic.List[string]]::new()
    $cursorHeads = 0
    $agyGHeads = 0
    $geminiHeads = 0

    if (-not (Test-JsonProperty -Object $Map -Name 'schemaVersion') -or $null -eq $Map.schemaVersion -or [string]$Map.schemaVersion -eq '') {
        $failures.Add('Seat map is missing required schemaVersion.')
        return @($failures)
    }

    $schemaRaw = $Map.schemaVersion
    if (-not (Test-SeatMapIsExactSchemaVersion2 -Raw $schemaRaw)) {
        $failures.Add((Get-SeatMapSchemaVersionDiagnostic -Got $schemaRaw))
        return @($failures)
    }

    $seats = @()
    if (Test-JsonProperty -Object $Map -Name 'seats') {
        $seats = @($Map.seats)
    }

    $seenIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenCodenames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($seat in $seats) {
        $codename = if (Test-JsonProperty -Object $seat -Name 'codename') { [string]$seat.codename } else { '' }
        $seatId = if (Test-JsonProperty -Object $seat -Name 'id') { [string]$seat.id } else { '' }
        $roleId = if (Test-JsonProperty -Object $seat -Name 'roleId') { [string]$seat.roleId } else { '' }
        $preset = if (Test-JsonProperty -Object $seat -Name 'preset') { [string]$seat.preset } else { '' }
        $name = if (Test-JsonProperty -Object $seat -Name 'name') { [string]$seat.name } else { '' }
        $label = if (-not [string]::IsNullOrWhiteSpace($codename)) { $codename } elseif (-not [string]::IsNullOrWhiteSpace($seatId)) { $seatId } else { '?' }

        if ([string]::IsNullOrWhiteSpace($seatId)) {
            $failures.Add("Seat '$label' is missing required id.")
        } elseif (-not $seenIds.Add($seatId)) {
            $failures.Add("Duplicate seat id '$seatId'.")
        }
        if ([string]::IsNullOrWhiteSpace($codename)) {
            $failures.Add("Seat '$label' is missing required codename.")
        } elseif (-not $seenCodenames.Add($codename)) {
            $failures.Add("Duplicate seat codename '$codename'.")
        }
        if ([string]::IsNullOrWhiteSpace($roleId)) {
            $failures.Add("Seat '$label' is missing required roleId.")
        }
        if ([string]::IsNullOrWhiteSpace($preset)) {
            $failures.Add("Seat '$label' is missing required preset.")
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $failures.Add("Seat '$label' is missing required name.")
        }

        $list = Get-SeatMapRungList -Seat $seat
        if ($null -eq $list) {
            $failures.Add("Seat '$label' rungs must be a JSON array.")
            continue
        }
        if ($list.Count -eq 0) {
            $failures.Add("Seat '$label' rungs array is empty.")
            continue
        }
        if ($list.Count -lt 4) {
            $failures.Add("Seat '$label' rungs array is short (found $($list.Count), required at least 4).")
        }

        $headIndexes = [System.Collections.Generic.List[int]]::new()
        $floorIndexes = [System.Collections.Generic.List[int]]::new()
        $seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $namedPools = [System.Collections.Generic.List[string]]::new()

        for ($i = 0; $i -lt $list.Count; $i++) {
            $cell = $list[$i]
            $r = ''
            if ($null -ne $cell -and (Test-JsonProperty -Object $cell -Name 'name')) {
                $r = [string]$cell.name
            }
            if ([string]::IsNullOrWhiteSpace($r)) {
                $failures.Add("Seat '$label' rung index $i is missing name.")
                $r = "index-$i"
            }
            else {
                if (-not (Test-SeatMapRungName -Name $r)) {
                    $failures.Add("Seat '$label' rung name '$r' is unsafe (expected ^[a-z][a-z0-9-]{0,30}$).")
                }
                if (-not $seenNames.Add($r)) {
                    $failures.Add("Seat '$label' has duplicate rung name '$r'.")
                }
            }

            if ($null -eq $cell) {
                $failures.Add("Seat '$label' rung '$r' is null.")
                continue
            }

            if ((Test-JsonProperty -Object $cell -Name 'role') -and -not [string]::IsNullOrWhiteSpace([string]$cell.role)) {
                $role = [string]$cell.role
                if ($role -ceq 'head') {
                    $headIndexes.Add($i)
                }
                elseif ($role -ceq 'floor') {
                    $floorIndexes.Add($i)
                }
                elseif ($validRoles -cnotcontains $role) {
                    $failures.Add("Seat '$label' rung '$r' has unknown role '$role' (expected head|floor).")
                }
            }

            if (-not (Test-JsonProperty -Object $cell -Name 'launch') -or [string]::IsNullOrWhiteSpace([string]$cell.launch)) {
                $failures.Add("Seat '$label' rung '$r' missing launch line.")
            }

            $pool = $null
            if (Test-JsonProperty -Object $cell -Name 'pool') { $pool = [string]$cell.pool }
            if ([string]::IsNullOrWhiteSpace($pool)) {
                $failures.Add("Seat '$label' rung '$r' missing pool.")
            } elseif ($validPools -notcontains $pool) {
                $failures.Add("Seat '$label' rung '$r' has unknown pool '$pool'.")
            } else {
                $namedPools.Add($pool)
            }

            if ((Test-JsonProperty -Object $cell -Name 'evidence') -and -not [string]::IsNullOrWhiteSpace([string]$cell.evidence)) {
                $evidence = [string]$cell.evidence
                if ($validEvidence -notcontains $evidence) {
                    $failures.Add("Seat '$label' rung '$r' has unknown evidence '$evidence'.")
                }
            }

            $hostName = $null
            if (Test-JsonProperty -Object $cell -Name 'host') { $hostName = [string]$cell.host }
            if ([string]::IsNullOrWhiteSpace($hostName)) {
                $failures.Add("Seat '$label' rung '$r' missing host.")
            } else {
                if ($knownHosts -notcontains $hostName) {
                    $failures.Add("Seat '$label' rung '$r' has unknown host '$hostName'.")
                }
                if ($hostName -eq 'opencode') {
                    $launch = if (Test-JsonProperty -Object $cell -Name 'launch') { [string]$cell.launch } else { '' }
                    if ($launch -notmatch '(^|\s)(-m|--model)(\s|=|$)') {
                        $failures.Add("Seat '$label' rung '$r' OpenCode launch line is missing -m/--model.")
                    }
                }
            }

            $modelName = $null
            if (Test-JsonProperty -Object $cell -Name 'model') { $modelName = [string]$cell.model }
            if ([string]::IsNullOrWhiteSpace($modelName)) {
                $failures.Add("Seat '$label' rung '$r' missing model.")
            }

            if (Test-JsonProperty -Object $cell -Name 'tier') {
                $tierRaw = $cell.tier
                if ($null -ne $tierRaw -and [string]$tierRaw -ne '') {
                    $tierNum = 0
                    $isNumeric = $tierRaw -is [int] -or $tierRaw -is [long] -or $tierRaw -is [decimal] -or $tierRaw -is [double]
                    if ($isNumeric) {
                        $tierNum = [int]$tierRaw
                    } else {
                        $parsed = [int]::TryParse([string]$tierRaw, [ref]$tierNum)
                        if (-not $parsed) { $tierNum = 0 }
                    }
                    if ($tierNum -lt 0 -or $tierNum -gt 4) {
                        $failures.Add("Seat '$codename' rung '$r' has invalid tier '$tierRaw' (expected 0-4).")
                    }
                }
            }

            if (Test-JsonProperty -Object $cell -Name 'evidenceDate') {
                $evidenceDate = [string]$cell.evidenceDate
                if ($evidenceDate -ne '' -and $evidenceDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
                    $failures.Add("Seat '$codename' rung '$r' has invalid evidenceDate format '$evidenceDate' (expected YYYY-MM-DD).")
                }
            }

            if ((Test-JsonProperty -Object $cell -Name 'cost') -and $null -ne $cell.cost) {
                $costSource = $null
                if (Test-JsonProperty -Object $cell.cost -Name 'source') { $costSource = $cell.cost.source }
                if (-not $costSource -or $validCostSources -notcontains $costSource) {
                    $failures.Add("Seat '$label' rung '$r' has invalid cost.source '$costSource' (expected actual|estimated|unknown).")
                }
                if ((Test-JsonProperty -Object $cell.cost -Name 'usd') -and $null -ne $cell.cost.usd) {
                    if (-not ($cell.cost.usd -is [int] -or $cell.cost.usd -is [long] -or $cell.cost.usd -is [double] -or $cell.cost.usd -is [decimal])) {
                        $failures.Add("Seat '$label' rung '$r' has non-numeric cost.usd '$($cell.cost.usd)'.")
                    }
                }
            }
        }

        if ($headIndexes.Count -eq 0) {
            $failures.Add("Seat '$label' is missing a rung with role 'head'.")
        } elseif ($headIndexes.Count -gt 1) {
            $failures.Add("Seat '$label' has duplicated role 'head'.")
        } elseif ($headIndexes[0] -ne 0) {
            $failures.Add("Seat '$label' role 'head' must be the first rung.")
        }

        if ($floorIndexes.Count -eq 0) {
            $failures.Add("Seat '$label' is missing a rung with role 'floor'.")
        } elseif ($floorIndexes.Count -gt 1) {
            $failures.Add("Seat '$label' has duplicated role 'floor'.")
        } elseif ($floorIndexes[0] -ne ($list.Count - 1)) {
            $failures.Add("Seat '$label' role 'floor' must be the last rung.")
        }

        if (-not (Test-JsonProperty -Object $seat -Name 'activeRung') -or [string]::IsNullOrWhiteSpace([string]$seat.activeRung)) {
            $failures.Add("Seat '$label' is missing required activeRung.")
        }
        else {
            $active = [string]$seat.activeRung
            if ($null -eq (Get-SeatMapRungByName -Seat $seat -Name $active)) {
                $failures.Add("Seat '$label' activeRung '$active' does not match a declared rung name.")
            }
        }

        $headCell = Get-SeatMapRungByRole -Seat $seat -Role 'head'
        $floorCell = Get-SeatMapRungByRole -Seat $seat -Role 'floor'
        $headPool = $null
        $floorPool = $null
        if ($null -ne $headCell -and (Test-JsonProperty -Object $headCell -Name 'pool')) { $headPool = [string]$headCell.pool }
        if ($null -ne $floorCell -and (Test-JsonProperty -Object $floorCell -Name 'pool')) { $floorPool = [string]$floorCell.pool }

        if ($headPool -eq 'CURSOR') { $cursorHeads++ }
        if ($headPool -eq 'AGY-G') { $agyGHeads++ }
        if ($headPool -eq 'GEMINI') { $geminiHeads++ }

        if ($disallowedFloorPools -contains $floorPool -and $zenFloorExceptions -notcontains $codename -and $zenFloorExceptions -notcontains $seatId) {
            $failures.Add("Seat '$label' has $floorPool on floor.")
        }

        if ($distinctPoolsPerSeat) {
            $unique = @($namedPools | Select-Object -Unique)
            if ($unique.Count -lt $namedPools.Count) {
                $failures.Add("Seat '$label' does not have distinct pools across all declared rungs (found: $($namedPools -join ', ')).")
            }
        }
    }

    if ($cursorHeads -gt $maxCursorHeads) {
        $failures.Add("At most $maxCursorHeads Cursor heads allowed (found $cursorHeads).")
    }
    if ($agyGHeads -gt $maxAgyGHeads) {
        $failures.Add("At most $maxAgyGHeads AGY-G heads allowed (found $agyGHeads).")
    }
    if ($geminiHeads -lt $minGeminiHeads) {
        $failures.Add("At least $minGeminiHeads Gemini heads required (found $geminiHeads).")
    }

    return @($failures)
}

function Get-SeatMapExpectedTier {
    <#
    Resolves the tier the map's own tierPolicy expects for a rung: the first
    modelTiers entry whose pool matches and whose modelPattern matches the model
    wins; otherwise poolTiers[pool]; otherwise $null (policy is silent).
    #>
    param($Policy, [string]$Pool, [string]$Model)
    if ($null -eq $Policy) { return $null }
    if (Test-JsonProperty -Object $Policy -Name 'modelTiers') {
        foreach ($mt in @($Policy.modelTiers)) {
            if ($null -eq $mt) { continue }
            $mtPool = if (Test-JsonProperty -Object $mt -Name 'pool') { [string]$mt.pool } else { '' }
            $mtPattern = if (Test-JsonProperty -Object $mt -Name 'modelPattern') { [string]$mt.modelPattern } else { '' }
            if ($mtPool -ne $Pool -or [string]::IsNullOrWhiteSpace($mtPattern)) { continue }
            if ($Model -match $mtPattern) { return [int]$mt.tier }
        }
    }
    if ((Test-JsonProperty -Object $Policy -Name 'poolTiers') -and (Test-JsonProperty -Object $Policy.poolTiers -Name $Pool)) {
        return [int]$Policy.poolTiers.$Pool
    }
    return $null
}

function Get-SeatMapWarnings {
    <#
    Advisory checks driven by invariants.tierPolicy. Every finding here is a
    warning: the operator may run any model on any seat, and the map must say
    when a choice crosses a stated preference, not refuse it. A map without a
    tierPolicy block produces no warnings. Nothing here changes the exit code.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Map
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-JsonProperty -Object $Map -Name 'invariants')) { return @() }
    if (-not (Test-JsonProperty -Object $Map.invariants -Name 'tierPolicy')) { return @() }
    $policy = $Map.invariants.tierPolicy
    if ($null -eq $policy) { return @() }

    $order = @()
    if (Test-JsonProperty -Object $policy -Name 'consumptionOrder') { $order = @($policy.consumptionOrder | ForEach-Object { [int]$_ }) }
    $rank = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $rank[$order[$i]] = $i }
    $orderText = $order -join ' > '

    $seats = @()
    if (Test-JsonProperty -Object $Map -Name 'seats') { $seats = @($Map.seats) }

    $activeByPool = @{}
    foreach ($seat in $seats) {
        $codename = if (Test-JsonProperty -Object $seat -Name 'codename') { [string]$seat.codename } else { '' }
        $seatId = if (Test-JsonProperty -Object $seat -Name 'id') { [string]$seat.id } else { '' }
        $label = if (-not [string]::IsNullOrWhiteSpace($codename)) { $codename } elseif (-not [string]::IsNullOrWhiteSpace($seatId)) { $seatId } else { '?' }
        $list = Get-SeatMapRungList -Seat $seat
        if ($null -eq $list -or $list.Count -eq 0) { continue }

        $activeName = if (Test-JsonProperty -Object $seat -Name 'activeRung') { [string]$seat.activeRung } else { '' }
        $prevRank = $null
        $prevName = ''
        $prevTier = $null
        foreach ($cell in $list) {
            if ($null -eq $cell) { continue }
            $r = if (Test-JsonProperty -Object $cell -Name 'name') { [string]$cell.name } else { '?' }
            $pool = if (Test-JsonProperty -Object $cell -Name 'pool') { [string]$cell.pool } else { '' }
            $model = if (Test-JsonProperty -Object $cell -Name 'model') { [string]$cell.model } else { '' }
            $tier = $null
            if ((Test-JsonProperty -Object $cell -Name 'tier') -and $null -ne $cell.tier -and [string]$cell.tier -ne '') {
                $parsedTier = 0
                if ([int]::TryParse([string]$cell.tier, [ref]$parsedTier)) { $tier = $parsedTier }
            }

            # tier-mismatch: the rung claims a tier the policy does not give that pool/model
            $expected = Get-SeatMapExpectedTier -Policy $policy -Pool $pool -Model $model
            if ($null -ne $expected -and $null -ne $tier -and $expected -ne $tier) {
                $warnings.Add("TIER  Seat '$label' rung '$r' declares tier $tier but tierPolicy puts $pool/$model at tier $expected.")
            }

            # chain-order: rungs should be read in consumption order (best first)
            $effective = if ($null -ne $tier) { $tier } else { $expected }
            if ($null -ne $effective -and $rank.ContainsKey($effective)) {
                $thisRank = $rank[$effective]
                if ($null -ne $prevRank -and $thisRank -lt $prevRank) {
                    $warnings.Add("ORDER Seat '$label' rung '$r' (tier $effective) sits below rung '$prevName' (tier $prevTier); consumption order is $orderText.")
                }
                $prevRank = $thisRank; $prevName = $r; $prevTier = $effective
            }

            # pool-model-preference: a pool the operator reserved for specific models
            if ((Test-JsonProperty -Object $policy -Name 'poolModelPreference') -and (Test-JsonProperty -Object $policy.poolModelPreference -Name $pool)) {
                $allowed = @($policy.poolModelPreference.$pool)
                $hit = $false
                foreach ($a in $allowed) { if ($model -like "*$a*") { $hit = $true; break } }
                if (-not $hit) {
                    $warnings.Add("MODEL Seat '$label' rung '$r' runs '$model' on $pool; the operator reserves $pool for: $($allowed -join ', ').")
                }
            }

            # pool-disallowed-seats: e.g. Zen never carries Rigger
            if ((Test-JsonProperty -Object $policy -Name 'poolDisallowedSeats') -and (Test-JsonProperty -Object $policy.poolDisallowedSeats -Name $pool)) {
                $banned = @($policy.poolDisallowedSeats.$pool)
                if ($banned -contains $seatId -or $banned -contains $codename) {
                    $warnings.Add("SEAT  Seat '$label' rung '$r' is on $pool, which the operator keeps off this seat.")
                }
            }

            # seat-pool-avoid: a pool observed to misbehave on this seat
            if (Test-JsonProperty -Object $policy -Name 'seatPoolAvoid') {
                foreach ($av in @($policy.seatPoolAvoid)) {
                    if ($null -eq $av) { continue }
                    $avSeat = if (Test-JsonProperty -Object $av -Name 'seat') { [string]$av.seat } else { '' }
                    $avPool = if (Test-JsonProperty -Object $av -Name 'pool') { [string]$av.pool } else { '' }
                    $avReason = if (Test-JsonProperty -Object $av -Name 'reason') { [string]$av.reason } else { 'no reason recorded' }
                    if ($avPool -eq $pool -and ($avSeat -eq $seatId -or $avSeat -eq $codename)) {
                        $warnings.Add("AVOID Seat '$label' rung '$r' is on ${pool}: $avReason")
                    }
                }
            }

            if ($r -eq $activeName -and -not [string]::IsNullOrWhiteSpace($pool)) {
                if (-not $activeByPool.ContainsKey($pool)) { $activeByPool[$pool] = [System.Collections.Generic.List[string]]::new() }
                $activeByPool[$pool].Add($label)
            }
        }

        # seat-head-pool-preference: which pool the operator wants at the head of this seat
        if (Test-JsonProperty -Object $policy -Name 'seatHeadPoolPreference') {
            $prefKey = $null
            if (Test-JsonProperty -Object $policy.seatHeadPoolPreference -Name $seatId) { $prefKey = $seatId }
            elseif (Test-JsonProperty -Object $policy.seatHeadPoolPreference -Name $codename) { $prefKey = $codename }
            if ($prefKey) {
                $preferred = @($policy.seatHeadPoolPreference.$prefKey)
                $headCell = Get-SeatMapRungByRole -Seat $seat -Role 'head'
                $headPool = if ($null -ne $headCell -and (Test-JsonProperty -Object $headCell -Name 'pool')) { [string]$headCell.pool } else { '' }
                if ($preferred -notcontains $headPool) {
                    $warnings.Add("HEAD  Seat '$label' head is on $headPool; the operator prefers $($preferred -join ' or ') for this seat.")
                }
            }
        }
    }

    # max-active-seats-per-pool: e.g. one Zen seat at a time, Codex = Conductor + one verifier
    if (Test-JsonProperty -Object $policy -Name 'maxActiveSeatsPerPool') {
        foreach ($p in $policy.maxActiveSeatsPerPool.PSObject.Properties) {
            $limit = [int]$p.Value
            [object[]]$on = @()
            if ($activeByPool.ContainsKey($p.Name)) { $on = @($activeByPool[$p.Name]) }
            if ($on.Count -gt $limit) {
                $warnings.Add("POOL  $($p.Name) is the active rung on $($on.Count) seats ($($on -join ', ')); the operator caps it at $limit.")
            }
        }
    }

    return @($warnings)
}

function Write-SeatMapWarnings {
    param([object[]]$Warnings)
    $list = @($Warnings)
    if ($list.Count -eq 0) { return }
    Write-Host "=== Tier policy warnings ($($list.Count)) - advisory only, the map still validates ===" -ForegroundColor Yellow
    foreach ($w in $list) { Write-Warning ([string]$w) }
}

function Get-SeatMapFloorPolicy {
    param(
        [Parameter(Mandatory = $true)]
        $Map
    )

    $disallowedFloorPools = @('ZEN')
    $zenFloorExceptions = @('Quill')
    if (Test-JsonProperty -Object $Map -Name 'invariants') {
        $invariants = $Map.invariants
        if (Test-JsonProperty -Object $invariants -Name 'disallowedFloorPools') {
            $disallowedFloorPools = @($invariants.disallowedFloorPools)
        }
        if (Test-JsonProperty -Object $invariants -Name 'zenFloorExceptions') {
            $zenFloorExceptions = @($invariants.zenFloorExceptions)
        }
    }
    return [pscustomobject]@{
        DisallowedFloorPools = @($disallowedFloorPools)
        ZenFloorExceptions   = @($zenFloorExceptions)
    }
}

function Get-SeatActiveRungName {
    param(
        [Parameter(Mandatory = $true)]
        $Seat
    )
    return (Get-SeatMapActiveRungName -Seat $Seat)
}

function Get-SeatMapSeatLabel {
    param(
        [Parameter(Mandatory = $true)]
        $Seat
    )
    $codename = if (Test-JsonProperty -Object $Seat -Name 'codename') { [string]$Seat.codename } else { '' }
    $seatId = if (Test-JsonProperty -Object $Seat -Name 'id') { [string]$Seat.id } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($codename)) { return $codename }
    if (-not [string]::IsNullOrWhiteSpace($seatId)) { return $seatId }
    return '?'
}

function ConvertTo-SeatMapTier {
    param($TierRaw)
    if ($null -eq $TierRaw -or [string]$TierRaw -eq '') { return $null }
    $tierNum = 0
    $isNumeric = $TierRaw -is [int] -or $TierRaw -is [long] -or $TierRaw -is [decimal] -or $TierRaw -is [double]
    if ($isNumeric) {
        return [int]$TierRaw
    }
    if ([int]::TryParse([string]$TierRaw, [ref]$tierNum)) {
        return $tierNum
    }
    return $null
}

function Test-SeatFloorPoolAllowed {
    param(
        [Parameter(Mandatory = $true)]
        $Seat,
        [string]$Pool,
        [Parameter(Mandatory = $true)]
        $Policy
    )
    $codename = if (Test-JsonProperty -Object $Seat -Name 'codename') { [string]$Seat.codename } else { '' }
    $seatId = if (Test-JsonProperty -Object $Seat -Name 'id') { [string]$Seat.id } else { '' }
    if ($Policy.DisallowedFloorPools -contains $Pool) {
        if ($Policy.ZenFloorExceptions -notcontains $codename -and $Policy.ZenFloorExceptions -notcontains $seatId) {
            return $false
        }
    }
    return $true
}

function Test-SeatMapRungIsFloorRole {
    param(
        $Seat,
        [string]$RungName,
        $Cell
    )
    if ([string]$RungName -ceq 'floor') { return $true }
    $c = $Cell
    if ($null -eq $c -and -not [string]::IsNullOrWhiteSpace($RungName)) {
        $c = Get-SeatMapRungByName -Seat $Seat -Name $RungName
    }
    if ($null -ne $c -and (Test-JsonProperty -Object $c -Name 'role') -and [string]$c.role -ceq 'floor') {
        return $true
    }
    return $false
}

function Get-SeatRuntimeFloorTieOrder {
    param(
        $Cell,
        [int]$Index
    )
    $name = ''
    $role = ''
    if ($null -ne $Cell) {
        if (Test-JsonProperty -Object $Cell -Name 'name') { $name = [string]$Cell.name }
        if (Test-JsonProperty -Object $Cell -Name 'role') { $role = [string]$Cell.role }
    }
    if ($role -ceq 'floor' -or $name -ceq 'floor') { return 0 }
    if ($name -ceq 'then') { return 1 }
    if ($role -ceq 'head' -or $name -ceq 'head') { return 1000 }
    return 10 + $Index
}

function Resolve-SeatRuntimeFloor {
    param(
        [Parameter(Mandatory = $true)]
        $Map,
        [Parameter(Mandatory = $true)]
        $Seat
    )

    $label = Get-SeatMapSeatLabel -Seat $Seat
    $policy = Get-SeatMapFloorPolicy -Map $Map
    $eligibleEvidence = @('measured', 'cleared')
    $list = Get-SeatMapRungList -Seat $Seat

    $headPool = ''
    $headCell = Get-SeatMapRungByRole -Seat $Seat -Role 'head'
    if ($null -ne $headCell -and (Test-JsonProperty -Object $headCell -Name 'pool')) {
        $headPool = [string]$headCell.pool
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $idx = 0
    foreach ($cell in @($list)) {
        $index = $idx
        $idx++
        if ($null -eq $cell) { continue }

        $r = "rung[$index]"
        if ((Test-JsonProperty -Object $cell -Name 'name') -and -not [string]::IsNullOrWhiteSpace([string]$cell.name)) {
            $r = [string]$cell.name
        }

        $evidence = ''
        if (Test-JsonProperty -Object $cell -Name 'evidence') { $evidence = [string]$cell.evidence }
        if ($eligibleEvidence -notcontains $evidence) { continue }

        $tierRaw = $null
        $hasTier = Test-JsonProperty -Object $cell -Name 'tier'
        if ($hasTier) { $tierRaw = $cell.tier }
        $tierNum = ConvertTo-SeatMapTier -TierRaw $tierRaw
        if (-not $hasTier -or $null -eq $tierNum) {
            return [pscustomobject]@{
                Ok       = $false
                Error    = "Seat '$label' measured/cleared rung '$r' has invalid tier (missing, blank, or non-numeric; runtime floor requires 1-4)."
                RungName = $null
                Cell     = $null
                Launch   = $null
                Pool     = $null
                Tier     = $null
            }
        }
        if ($tierNum -lt 1 -or $tierNum -gt 4) { continue }

        $pool = ''
        if (Test-JsonProperty -Object $cell -Name 'pool') { $pool = [string]$cell.pool }
        if (-not (Test-SeatFloorPoolAllowed -Seat $Seat -Pool $pool -Policy $policy)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($headPool) -and $pool -eq $headPool) { continue }

        $launch = ''
        if (Test-JsonProperty -Object $cell -Name 'launch') { $launch = [string]$cell.launch }
        $candidates.Add([pscustomobject]@{
                RungName = $r
                Cell     = $cell
                Launch   = $launch
                Pool     = $pool
                Tier     = $tierNum
                Order    = Get-SeatRuntimeFloorTieOrder -Cell $cell -Index $index
            })
    }

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            Ok       = $false
            Error    = "Seat '$label' has no capable runtime floor (need measured or cleared evidence, numeric tier 1-4, floor-safe pool, and a pool other than this seat's head pool)."
            RungName = $null
            Cell     = $null
            Launch   = $null
            Pool     = $null
            Tier     = $null
        }
    }

    $chosen = @($candidates | Sort-Object Tier, Order)[0]
    return [pscustomobject]@{
        Ok       = $true
        Error    = $null
        RungName = [string]$chosen.RungName
        Cell     = $chosen.Cell
        Launch   = [string]$chosen.Launch
        Pool     = [string]$chosen.Pool
        Tier     = [int]$chosen.Tier
    }
}

function Get-SeatActiveLaunchCell {
    param(
        [Parameter(Mandatory = $true)]
        $Seat,
        $RuntimeFloor
    )
    $key = Get-SeatMapActiveRungName -Seat $Seat
    $activeCell = Get-SeatMapRungByName -Seat $Seat -Name $key
    if ((Test-SeatMapRungIsFloorRole -Seat $Seat -RungName $key -Cell $activeCell) -and $null -ne $RuntimeFloor -and [bool]$RuntimeFloor.Ok) {
        return $RuntimeFloor.Cell
    }
    return $activeCell
}

function Get-SeatMapTargetSwapDecision {
    param(
        [Parameter(Mandatory = $true)]
        $Seat,
        [Parameter(Mandatory = $true)]
        [string]$RungName,
        $RuntimeFloor
    )
    $rungCell = Get-SeatMapRungByName -Seat $Seat -Name $RungName
    $useFloor = ($null -ne $RuntimeFloor -and [bool]$RuntimeFloor.Ok -and (Test-SeatMapRungIsFloorRole -Seat $Seat -RungName $RungName -Cell $rungCell))
    $launch = ''
    $pool = ''
    if ($useFloor) {
        $launch = [string]$RuntimeFloor.Launch
        $pool = [string]$RuntimeFloor.Pool
    }
    else {
        if ($null -ne $rungCell -and (Test-JsonProperty -Object $rungCell -Name 'launch')) { $launch = [string]$rungCell.launch }
        if ($null -ne $rungCell -and (Test-JsonProperty -Object $rungCell -Name 'pool')) { $pool = [string]$rungCell.pool }
    }
    $previousRung = Get-SeatActiveRungName -Seat $Seat
    $previousLaunch = ''
    $previousPool = ''
    $prevCell = Get-SeatMapRungByName -Seat $Seat -Name $previousRung
    if ($null -ne $prevCell) {
        if (Test-JsonProperty -Object $prevCell -Name 'launch') { $previousLaunch = [string]$prevCell.launch }
        if (Test-JsonProperty -Object $prevCell -Name 'pool') { $previousPool = [string]$prevCell.pool }
    }
    $codeName = if (Test-JsonProperty -Object $Seat -Name 'codename') { [string]$Seat.codename } else { '' }
    $preset = if (Test-JsonProperty -Object $Seat -Name 'preset') { [string]$Seat.preset } else { '' }
    $seatId = if (Test-JsonProperty -Object $Seat -Name 'id') { [string]$Seat.id } else { '' }
    return [pscustomobject]@{
        SeatId             = $seatId
        Codename           = $codeName
        Preset             = $preset
        ActiveRung         = $RungName
        Launch             = $launch
        Pool               = $pool
        PreviousActiveRung = $previousRung
        PreviousLaunch     = $previousLaunch
        PreviousPool       = $previousPool
    }
}

function Format-SeatMapLockedSwapLine {
    param(
        [Parameter(Mandatory = $true)]
        $Decision
    )
    $payload = [ordered]@{
        seat               = [string]$Decision.Codename
        seatId             = [string]$Decision.SeatId
        activeRung         = [string]$Decision.ActiveRung
        launch             = [string]$Decision.Launch
        pool               = [string]$Decision.Pool
        previousActiveRung = [string]$Decision.PreviousActiveRung
        previousLaunch     = [string]$Decision.PreviousLaunch
        previousPool       = [string]$Decision.PreviousPool
        preset             = [string]$Decision.Preset
    } | ConvertTo-Json -Compress
    return "[SEAT-MAP LOCKED-SWAP] $payload"
}

function Read-SeatMapLockedSwapReceipt {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $prefix = '[SEAT-MAP LOCKED-SWAP] '
    foreach ($line in ($Text -split "`r?`n")) {
        $trim = [string]$line
        if ($trim.StartsWith($prefix)) {
            return ($trim.Substring($prefix.Length) | ConvertFrom-Json)
        }
    }
    return $null
}

function Resolve-MaestriWorkspaceId {
    param(
        [string]$WorkspaceId,
        [string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        return $WorkspaceId.Trim()
    }

    $wsRoot = Join-Path $HOME '.maestri' 'workspaces'
    if (-not (Test-Path -LiteralPath $wsRoot)) {
        throw "Maestri workspaces directory not found: $wsRoot"
    }

    $dirs = @(Get-ChildItem -LiteralPath $wsRoot -Directory -ErrorAction Stop)
    if ($dirs.Count -eq 0) {
        throw "No Maestri workspaces under $wsRoot"
    }

    $matched = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $hints = @(Get-MaestriRepoRootHints -RepoRoot $RepoRoot)
        foreach ($d in $dirs) {
            $wj = Join-Path $d.FullName 'workspace.json'
            if (-not (Test-Path -LiteralPath $wj)) { continue }
            $text = Get-Content -LiteralPath $wj -Raw
            $hit = $false
            foreach ($h in $hints) {
                if ($text.Contains($h)) { $hit = $true; break }
            }
            if ($hit) { $matched.Add($d.Name) }
        }
    }

    if ($matched.Count -eq 1) { return $matched[0] }
    if ($matched.Count -gt 1) {
        throw "Multiple Maestri workspaces match this repo. Candidates: $($matched -join ', ')"
    }
    # Hint matched nothing: do not silently fall back to a sole workspace.
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw "Repo-root hint matched no Maestri workspace. Found: $($dirs.Name -join ', ')"
    }
    if ($dirs.Count -eq 1) { return $dirs[0].Name }
    throw "Repo-root hint matched no Maestri workspace and $($dirs.Count) workspaces exist. Found: $($dirs.Name -join ', ')"
}

function Get-MaestriRepoRootHints {
    param([string]$RepoRoot)

    $hints = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    $addPath = {
        param([string]$PathValue)
        if ([string]::IsNullOrWhiteSpace($PathValue)) { return }
        $trimmed = $PathValue.Trim()
        $fwd = $trimmed.Replace('\', '/')
        $bwd = $trimmed.Replace('/', '\')
        $esc = $bwd.Replace('\', '\\')
        foreach ($form in @($trimmed, $fwd, $bwd, $esc)) {
            if ($seen.Add($form)) { $hints.Add($form) }
        }
    }

    & $addPath $RepoRoot
    try {
        $porcelain = & git -C $RepoRoot worktree list --porcelain 2>$null
        foreach ($line in @($porcelain)) {
            if ([string]$line -match '^worktree\s+(.+)$') {
                & $addPath $Matches[1]
            }
        }
    }
    catch {
        # Keep RepoRoot-only hints when git is unavailable.
    }

    return @($hints)
}

function Get-SeatMapExamplePath {
    return Join-Path $PSScriptRoot 'seat-map.example.json'
}

function Get-LiveSeatMapPath {
    param([string]$WorkspaceId)
    $id = if ([string]::IsNullOrWhiteSpace($WorkspaceId)) { '<id>' } else { $WorkspaceId }
    return Join-Path $HOME '.maestri' 'workspaces' $id 'seat-map.json'
}

function Resolve-LiveSeatMapPath {
    param(
        [string]$SeatMapPath,
        [string]$WorkspaceId,
        [string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($SeatMapPath)) {
        $id = $WorkspaceId
        if ([string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($RepoRoot)) {
            try {
                $id = Resolve-MaestriWorkspaceId -WorkspaceId $WorkspaceId -RepoRoot $RepoRoot
            }
            catch {
                $id = ''
            }
        }
        return [pscustomobject]@{
            Ok          = $true
            Path        = $SeatMapPath
            WorkspaceId = $id
            Explicit    = $true
        }
    }

    try {
        $id = Resolve-MaestriWorkspaceId -WorkspaceId $WorkspaceId -RepoRoot $RepoRoot
        return [pscustomobject]@{
            Ok          = $true
            Path        = Get-LiveSeatMapPath -WorkspaceId $id
            WorkspaceId = $id
            Explicit    = $false
        }
    }
    catch {
        return [pscustomobject]@{
            Ok          = $false
            Path        = Get-LiveSeatMapPath -WorkspaceId $WorkspaceId
            WorkspaceId = $WorkspaceId
            Explicit    = $false
            Error       = $_.Exception.Message
        }
    }
}

function Write-SeatMapMissingMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    [Console]::Error.WriteLine("Seat map file not found at: $Path. Pass -Init to copy the example into place.")
}

function Write-SeatMapResolutionFailureMessage {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ResolverError
    )
    $reason = [string]$ResolverError
    if ($reason.EndsWith('.')) {
        $reason = $reason.Substring(0, $reason.Length - 1)
    }
    [Console]::Error.WriteLine("Seat map workspace could not be resolved: $reason. Pass -WorkspaceId or -SeatMapPath.")
}

# DEV-241: cross-process exclusive FileStream (FileShare.None) keyed to a
# canonical target path. The OS releases the handle when the holder exits, so
# there is no PID file, no stale-mtime reclaim, and no unreadable-lock denial.
# A leftover sibling `.lock` file is only a token; the next opener succeeds.
# Contention is fail-fast (IOException / sharing violation) rather than wait.
function Get-ExclusiveFileLockPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )
    return [System.IO.Path]::GetFullPath($TargetPath) + '.lock'
}

function Enter-ExclusiveFileLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [Parameter(Mandatory = $true)]
        [string]$HeldMessage
    )
    $lockPath = Get-ExclusiveFileLockPath -TargetPath $TargetPath
    $dir = [System.IO.Path]::GetDirectoryName($lockPath)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    try {
        return [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        [Console]::Error.WriteLine("$HeldMessage ($lockPath).")
        exit 1
    }
    catch [System.UnauthorizedAccessException] {
        [Console]::Error.WriteLine("Lock open denied ($lockPath).")
        exit 1
    }
}

function Exit-ExclusiveFileLock {
    param($Handle)
    if ($null -eq $Handle) { return }
    try { $Handle.Dispose() } catch { }
}

function Get-SeatMapProcessLockPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeatMapPath
    )
    return Get-ExclusiveFileLockPath -TargetPath $SeatMapPath
}

function Enter-SeatMapProcessLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeatMapPath
    )
    return Enter-ExclusiveFileLock -TargetPath $SeatMapPath -HeldMessage 'Seat-map lock held'
}

function Exit-SeatMapProcessLock {
    param($Handle)
    Exit-ExclusiveFileLock -Handle $Handle
}

function Save-SeatMapFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $replaced = $false
    try {
        [System.IO.File]::WriteAllText($temp, $Content, $utf8)
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temp, $Path)
        }
        $replaced = $true
    }
    finally {
        if ($replaced) {
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            if ((Test-Path -LiteralPath $Path) -and (Test-Path -LiteralPath $temp)) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Save-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )
    Save-SeatMapFile -Path $Path -Content $Content
}

function Replace-LiteralRegex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Replacement
    )
    # MatchEvaluator returns the replacement as a literal, so '$' in launch
    # lines is not interpreted as a .NET substitution group.
    return [regex]::Replace($InputText, $Pattern, { param($m) $Replacement })
}

function Get-ModelChainLine {
    param(
        [Parameter(Mandatory = $true)]
        $Seat,
        [string]$FloorLaunch
    )
    $list = Get-SeatMapRungList -Seat $Seat
    if ($null -eq $list -or @($list).Count -eq 0) {
        return 'Model chain (best first): (FLOOR).'
    }
    $parts = @(
        foreach ($cell in @($list)) {
            if ($null -ne $cell -and (Test-JsonProperty -Object $cell -Name 'launch')) {
                [string]$cell.launch
            }
            else {
                ''
            }
        }
    )
    if (-not [string]::IsNullOrWhiteSpace($FloorLaunch) -and $parts.Count -gt 0) {
        $parts[$parts.Count - 1] = $FloorLaunch
    }
    return "Model chain (best first): $($parts -join ' -> ') (FLOOR)."
}

function Write-SeatMapSwapLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seat,
        [Parameter(Mandatory = $true)]
        [string]$Rung,
        [Parameter(Mandatory = $true)]
        [string]$Launch,
        [string]$Pool,
        [string]$PreviousActiveRung,
        [string]$PreviousLaunch,
        [string]$PreviousPool,
        [bool]$LiveSwapped,
        [string]$Detail,
        [string]$WorkspaceId
    )
    $dir = Join-Path $HOME '.maestri'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $logPath = Join-Path $dir 'seat-map-swaps.jsonl'
    $entry = [ordered]@{
        at                  = (Get-Date).ToString('o')
        workspaceId         = $WorkspaceId
        seat                = $Seat
        previousActiveRung  = $PreviousActiveRung
        previousLaunch      = $PreviousLaunch
        previousPool        = $PreviousPool
        rung                = $Rung
        launch              = $Launch
        pool                = $Pool
        liveSwapped         = [bool]$LiveSwapped
        detail              = $Detail
    } | ConvertTo-Json -Compress
    Add-Content -LiteralPath $logPath -Value $entry -Encoding utf8
}
