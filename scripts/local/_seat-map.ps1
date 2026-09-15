# Shared seat-map helpers. Dot-sourced by Test-SeatMap, Sync-SeatMap,
# Start-SeatMapServer, and Test-ModelProbe so charter invariants (including the
# Quill ZEN-floor exception) cannot drift between the CI gate, the
# synchronizer, the portal, and the probe writer.

. (Join-Path $PSScriptRoot '_json-property.ps1')

function Get-SeatMapViolations {
    param(
        [Parameter(Mandatory = $true)]
        $Map
    )

    $knownHosts = @('claude', 'cursor', 'agy', 'junie', 'gemini', 'opencode', 'codex')
    $validEvidence = @('measured', 'cleared', 'probed', 'unmeasured')
    $validPools = @('CLAUDE', 'CODEX', 'CURSOR', 'AGY-G', 'AGY-C', 'JETBRAINS', 'GEMINI', 'OPENROUTER', 'ZEN')
    $validCostSources = @('actual', 'estimated', 'unknown')
    $rungNames = @('head', 'then', 'floor')

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

        $rungs = $null
        if (Test-JsonProperty -Object $seat -Name 'rungs') { $rungs = $seat.rungs }

        $poolAt = @{}
        foreach ($r in $rungNames) {
            $cell = $null
            if (Test-JsonProperty -Object $rungs -Name $r) { $cell = $rungs.$r }
            if ($null -eq $cell) {
                $failures.Add("Seat '$label' is missing '$r' rung.")
                continue
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
            }
            $poolAt[$r] = $pool

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
                    if ($tierNum -lt 1 -or $tierNum -gt 4) {
                        $failures.Add("Seat '$codename' rung '$r' has invalid tier '$tierRaw' (expected 1-4).")
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

        if ($poolAt['head'] -eq 'CURSOR') { $cursorHeads++ }
        if ($poolAt['head'] -eq 'AGY-G') { $agyGHeads++ }
        if ($poolAt['head'] -eq 'GEMINI') { $geminiHeads++ }

        if ($disallowedFloorPools -contains $poolAt['floor'] -and $zenFloorExceptions -notcontains $codename -and $zenFloorExceptions -notcontains $seatId) {
            $failures.Add("Seat '$label' has $($poolAt['floor']) on floor.")
        }

        if ($distinctPoolsPerSeat) {
            $pools = @($poolAt['head'], $poolAt['then'], $poolAt['floor'])
            $unique = @($pools | Where-Object { $_ } | Select-Object -Unique)
            if ($unique.Count -lt 3) {
                $failures.Add("Seat '$label' does not have 3 distinct pools (found: $($pools -join ', ')).")
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
        throw "Maestri workspaces directory not found: $wsRoot. Pass -WorkspaceId."
    }

    $dirs = @(Get-ChildItem -LiteralPath $wsRoot -Directory -ErrorAction Stop)
    if ($dirs.Count -eq 0) {
        throw "No Maestri workspaces under $wsRoot. Pass -WorkspaceId."
    }

    $matched = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $hintFwd = $RepoRoot.Replace('\', '/')
        $hintBwd = $RepoRoot.Replace('/', '\')
        $hintEsc = $hintBwd.Replace('\', '\\')
        foreach ($d in $dirs) {
            $wj = Join-Path $d.FullName 'workspace.json'
            if (-not (Test-Path -LiteralPath $wj)) { continue }
            $text = Get-Content -LiteralPath $wj -Raw
            if ($text.Contains($hintFwd) -or $text.Contains($hintBwd) -or $text.Contains($hintEsc)) {
                $matched.Add($d.Name)
            }
        }
    }

    if ($matched.Count -eq 1) { return $matched[0] }
    if ($matched.Count -gt 1) {
        throw "Multiple Maestri workspaces match this repo. Pass -WorkspaceId. Candidates: $($matched -join ', ')"
    }
    # Hint matched nothing: do not silently fall back to a sole workspace.
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw "Repo-root hint matched no Maestri workspace. Pass -WorkspaceId. Found: $($dirs.Name -join ', ')"
    }
    if ($dirs.Count -eq 1) { return $dirs[0].Name }
    throw "Repo-root hint matched no Maestri workspace and $($dirs.Count) workspaces exist. Pass -WorkspaceId. Found: $($dirs.Name -join ', ')"
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
    try {
        [System.IO.File]::WriteAllText($temp, $Content, $utf8)
        [System.IO.File]::Move($temp, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
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
        $Seat
    )
    $head = [string]$Seat.rungs.head.launch
    $then = [string]$Seat.rungs.then.launch
    $floor = [string]$Seat.rungs.floor.launch
    return "Model chain (best first): $head -> $then -> $floor (FLOOR)."
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
