<#
.SYNOPSIS
    Four-way synchronizer for Maestri seat assignments (live workspace seat-map.json).
.DESCRIPTION
    Propagates the active rung from the live workspace seat map
    (~/.maestri/workspaces/<id>/seat-map.json) across:
    1. Role prompts (.maestri/roles/*/role.json) — all three rungs
    2. Canvas Note 1 (harness-team-charter.md roster table)
    3. Canvas Note 2 (team-restart.md launch commands)
    4. Printed `maestri recruit --replace` commands (-GenerateCommands)

    Runtime contract is `activeRung` (head|then|floor), the same field the
    portal writes. A target swap (`-Seat` + `-Rung`) preflights runtime FLOOR
    selection before any write and propagates that FLOOR into the target
    role model-chain line. Invariant violations always exit 1 (Quill ZEN-floor
    exception matches Test-SeatMap.ps1). An explicit -SeatMapPath overrides
    workspace discovery. Path resolution is lazy (after helpers are
    dot-sourced) so a missing workspace never throws at bind time.
.PARAMETER SeatMapPath
    Path to seat-map.json. Empty (default) resolves the live workspace path.
.PARAMETER Seat
    Seat id or codename to update.
.PARAMETER Rung
    Declared rung name to set as activeRung (schemaVersion-2 named rungs).
.PARAMETER WorkspaceId
    Maestri workspace UUID. Auto-discovered from ~/.maestri/workspaces when omitted.
.PARAMETER SyncRoles
    Update role.json model-chain lines.
.PARAMETER SyncNotes
    Update canvas notes (charter and restart).
.PARAMETER Verify
    Check drift against the workspace.json terminals. Not a merge-bar gate.
.PARAMETER GenerateCommands
    Print maestri recruit --replace commands.
.PARAMETER Validate
    Validate schema and charter invariants, then exit.
.PARAMETER Init
    Copy scripts/local/seat-map.example.json to the resolved target. Refuses
    an existing target (no -Force). Not a restore from the swap log.
.PARAMETER All
    Validate, print recruit commands, and sync roles and notes.
#>
[CmdletBinding()]
param(
    [string]$SeatMapPath,
    [string]$Seat,
    [string]$Rung,
    [string]$WorkspaceId,
    [switch]$SyncRoles,
    [switch]$SyncNotes,
    [switch]$Verify,
    [switch]$GenerateCommands,
    [switch]$Validate,
    [switch]$Init,
    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_seat-map.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
$resolvedMap = Resolve-LiveSeatMapPath -SeatMapPath $SeatMapPath -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
$SeatMapPath = $resolvedMap.Path
$resolvedWorkspaceId = [string]$resolvedMap.WorkspaceId

if ($Init) {
    if (-not $resolvedMap.Ok) {
        Write-SeatMapResolutionFailureMessage -ResolverError ([string]$resolvedMap.Error)
        exit 1
    }
    if (Test-Path -LiteralPath $SeatMapPath) {
        Write-Error "Refusing -Init: target already exists at: $SeatMapPath" -ErrorAction Continue
        exit 1
    }
    Write-Host 'Creating from example; not restoring previous state. Swap log: ~/.maestri/seat-map-swaps.jsonl'
    $swapLogPath = Join-Path $HOME '.maestri' 'seat-map-swaps.jsonl'
    if ((Test-Path -LiteralPath $swapLogPath) -and ((Get-Item -LiteralPath $swapLogPath).Length -gt 0)) {
        Write-Warning "Swap log is non-empty at $swapLogPath; -Init copies the example and does not restore previous state."
    }
    $examplePath = Get-SeatMapExamplePath
    if (-not (Test-Path -LiteralPath $examplePath)) {
        Write-Error "Seat map example not found at: $examplePath" -ErrorAction Continue
        exit 1
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $exampleContent = [System.IO.File]::ReadAllText($examplePath, $utf8)
    Save-SeatMapFile -Path $SeatMapPath -Content $exampleContent
    exit 0
}

if (-not $resolvedMap.Ok) {
    Write-SeatMapResolutionFailureMessage -ResolverError ([string]$resolvedMap.Error)
    exit 1
}
if (-not (Test-Path -LiteralPath $SeatMapPath)) {
    Write-SeatMapMissingMessage -Path $SeatMapPath
    exit 1
}

$seatMap = Get-Content -LiteralPath $SeatMapPath -Raw | ConvertFrom-Json
$syncMisses = [System.Collections.Generic.List[string]]::new()
$swapTarget = $null
$targetRuntimeFloor = $null

function Write-ViolationsAndExit {
    param([object[]]$Violations)
    if (@($Violations).Count -eq 0) { return }
    $Violations | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

function Get-SeatByName {
    param($Map, [string]$Name)
    foreach ($s in @($Map.seats)) {
        if ($s.id -eq $Name -or $s.codename -eq $Name -or $s.name -eq $Name) {
            return $s
        }
    }
    return $null
}

function Save-SeatMap {
    param($Map, [string]$Path)
    $json = $Map | ConvertTo-Json -Depth 12
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    Save-SeatMapFile -Path $Path -Content $json
}

$rosterHeaderPattern = '(?ms)\| Seat \| Codename \| Agent \+ model \((?:head|active)\) \| Pool \|.+?\n\n'
$launchHeaderPattern = '(?ms)\| Seat \| Launch command \|.+?\n\n'
$swapRollback = $null

function Add-SwapRollbackPath {
    param([string]$Path)
    if ($null -eq $script:swapRollback) { return }
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ($script:swapRollback.Contains($Path)) { return }
    $existed = Test-Path -LiteralPath $Path
    $bytes = $null
    if ($existed) { $bytes = [System.IO.File]::ReadAllBytes($Path) }
    $script:swapRollback[$Path] = [pscustomobject]@{ Existed = [bool]$existed; Bytes = $bytes }
}

function Restore-SwapRollback {
    if ($null -eq $script:swapRollback) { return }
    foreach ($path in @($script:swapRollback.Keys)) {
        $snap = $script:swapRollback[$path]
        if ($snap.Existed) {
            [System.IO.File]::WriteAllBytes($path, $snap.Bytes)
        } elseif (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-TargetSwapNotePaths {
    param(
        [string]$WorkspaceIdParam,
        [string]$RepoRootParam
    )
    $resolvedWorkspace = Resolve-MaestriWorkspaceId -WorkspaceId $WorkspaceIdParam -RepoRoot $RepoRootParam
    $notesDir = Join-Path $HOME '.maestri' 'workspaces' $resolvedWorkspace 'notes'
    return [pscustomobject]@{
        NotesDir    = $notesDir
        CharterPath = Join-Path $notesDir 'harness-team-charter.md'
        RestartPath = Join-Path $notesDir 'team-restart.md'
    }
}

function Get-TargetSwapNoteMisses {
    param($NotePaths)
    $misses = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $NotePaths.NotesDir)) {
        $misses.Add("Notes directory not found at: $($NotePaths.NotesDir)")
        return @($misses)
    }
    if (-not (Test-Path -LiteralPath $NotePaths.CharterPath)) {
        $misses.Add("harness-team-charter.md not found at: $($NotePaths.CharterPath)")
    } else {
        $charterContent = Get-Content -LiteralPath $NotePaths.CharterPath -Raw
        if ($charterContent -notmatch $rosterHeaderPattern) {
            $misses.Add('Could not find Roster table in harness-team-charter.md')
        }
    }
    if (-not (Test-Path -LiteralPath $NotePaths.RestartPath)) {
        $misses.Add("team-restart.md not found at: $($NotePaths.RestartPath)")
    } else {
        $restartContent = Get-Content -LiteralPath $NotePaths.RestartPath -Raw
        if ($restartContent -notmatch $launchHeaderPattern) {
            $misses.Add('Could not find Launch commands table in team-restart.md')
        }
    }
    return @($misses)
}

$violations = @(Get-SeatMapViolations -Map $seatMap)
$noAction = -not ($Seat -or $SyncRoles -or $SyncNotes -or $Verify -or $GenerateCommands -or $All)
if ($Validate -or $All -or $noAction) {
    Write-Host "Validating seat map at: $SeatMapPath"
    if (-not [string]::IsNullOrWhiteSpace($resolvedWorkspaceId)) {
        Write-Host "Workspace id: $resolvedWorkspaceId"
    }
    Write-Host '=== Validating Seat Map Invariants ===' -ForegroundColor Cyan
    Write-ViolationsAndExit -Violations $violations
    Write-Host 'All charter invariants PASSED:' -ForegroundColor Green
    Write-Host '  [OK] At most 2 Cursor heads'
    Write-Host '  [OK] At most 1 AGY-G head'
    Write-Host '  [OK] At least 1 Gemini API head'
    Write-Host '  [OK] Zen floor = 0 (Quill excepted)'
    Write-Host '  [OK] Distinct pools across all declared rungs'
    Write-SeatMapWarnings -Warnings @(Get-SeatMapWarnings -Map $seatMap)
    if ($Validate -and -not $All -and -not $Seat -and -not $SyncRoles -and -not $SyncNotes -and -not $Verify -and -not $GenerateCommands) {
        exit 0
    }
} else {
    Write-ViolationsAndExit -Violations $violations
}

if ($Seat -and -not $Rung) {
    throw '-Rung is required when -Seat is set.'
}
if ($Rung -and -not $Seat) {
    throw '-Seat is required when -Rung is set.'
}

if ($Seat -and $Rung) {
    $swapTarget = Get-SeatByName -Map $seatMap -Name $Seat
    if ($null -eq $swapTarget) {
        throw "Seat '$Seat' not found in seat map."
    }
    if ($null -eq (Get-SeatMapRungByName -Seat $swapTarget -Name $Rung)) {
        throw "Seat '$Seat' has no declared rung '$Rung'."
    }
    $targetRuntimeFloor = Resolve-SeatRuntimeFloor -Map $seatMap -Seat $swapTarget
    if (-not $targetRuntimeFloor.Ok) {
        Write-Error $targetRuntimeFloor.Error -ErrorAction Continue
        exit 1
    }
    $swapTarget.activeRung = $Rung
    $after = @(Get-SeatMapViolations -Map $seatMap)
    Write-ViolationsAndExit -Violations $after

    $rolesDirForSwap = Join-Path $repoRoot '.maestri' 'roles'
    $swapRoleFile = Join-Path $rolesDirForSwap $swapTarget.roleId 'role.json'
    $swapRoleJson = $null
    $swapChainLine = $null
    if (Test-Path -LiteralPath $swapRoleFile) {
        $swapRoleJson = Get-Content -LiteralPath $swapRoleFile -Raw | ConvertFrom-Json
        $swapChainLine = Get-ModelChainLine -Seat $swapTarget -FloorLaunch $targetRuntimeFloor.Launch
        if ($swapRoleJson.prompt -notmatch '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
            Write-Error "Seat '$($swapTarget.codename)' role file has no Model chain line; refusing target swap before writes." -ErrorAction Continue
            exit 1
        }
        $swapRoleJson.prompt = Replace-LiteralRegex -InputText $swapRoleJson.prompt -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $swapChainLine
    }

    if ($SyncNotes -or $All) {
        try {
            $preflightNotes = Get-TargetSwapNotePaths -WorkspaceIdParam $WorkspaceId -RepoRootParam $repoRoot
        } catch {
            Write-Error ([string]$_) -ErrorAction Continue
            exit 1
        }
        Write-ViolationsAndExit -Violations @(Get-TargetSwapNoteMisses -NotePaths $preflightNotes)
    }

    $script:swapRollback = [ordered]@{}
    Add-SwapRollbackPath -Path $SeatMapPath
    Add-SwapRollbackPath -Path $swapRoleFile
    if ($SyncRoles -or $All) {
        $rolesDirForRollback = Join-Path $repoRoot '.maestri' 'roles'
        foreach ($s in @($seatMap.seats)) {
            if (Test-JsonProperty -Object $s -Name 'roleId') {
                Add-SwapRollbackPath -Path (Join-Path $rolesDirForRollback $s.roleId 'role.json')
            }
        }
    }
    if ($SyncNotes -or $All) {
        Add-SwapRollbackPath -Path $preflightNotes.CharterPath
        Add-SwapRollbackPath -Path $preflightNotes.RestartPath
    }
    trap {
        Restore-SwapRollback
        exit 1
    }

    Save-SeatMap -Map $seatMap -Path $SeatMapPath
    if ($null -ne $swapRoleJson) {
        Save-SeatMap -Map $swapRoleJson -Path $swapRoleFile
    }
    Write-Host "Updated seat '$($swapTarget.codename)' activeRung to '$Rung'." -ForegroundColor Green
    if ($null -ne $swapRoleJson) {
        Write-Host "  Updated role model-chain FLOOR for $($swapTarget.codename) to runtime floor '$($targetRuntimeFloor.Launch)'." -ForegroundColor Green
    }
}

if ($GenerateCommands -or $All) {
    Write-Host "`n=== Maestri Replacement Commands (maestri recruit --replace) ===" -ForegroundColor Cyan
    foreach ($s in @($seatMap.seats)) {
        $runtimeFloor = $null
        if ($null -ne $swapTarget -and $s.id -eq $swapTarget.id) { $runtimeFloor = $targetRuntimeFloor }
        $activeCell = Get-SeatActiveLaunchCell -Seat $s -RuntimeFloor $runtimeFloor
        $codeName = if (Test-JsonProperty -Object $s -Name 'codename') { [string]$s.codename } else { '' }
        $preset = if (Test-JsonProperty -Object $s -Name 'preset') { [string]$s.preset } else { '' }
        $launch = if ($null -ne $activeCell -and (Test-JsonProperty -Object $activeCell -Name 'launch')) { [string]$activeCell.launch } else { '' }
        Write-Host (Get-SeatMapRecruitCommand -Codename $codeName -Preset $preset -Launch $launch)
    }
}

if ($SyncRoles -or $All) {
    Write-Host "`n=== Syncing Role Prompts (.maestri/roles/) ===" -ForegroundColor Cyan
    $rolesDir = Join-Path $repoRoot '.maestri' 'roles'
    if (-not (Test-Path -LiteralPath $rolesDir)) {
        $syncMisses.Add("Roles directory not found at: $rolesDir")
        Write-Warning "Roles directory not found at: $rolesDir"
    } else {
        foreach ($s in @($seatMap.seats)) {
            $roleFile = Join-Path $rolesDir $s.roleId 'role.json'
            if (-not (Test-Path -LiteralPath $roleFile)) {
                $msg = "Role file not found for $($s.codename): $roleFile"
                $syncMisses.Add($msg)
                Write-Warning "  $msg"
                continue
            }
            $roleJson = Get-Content -LiteralPath $roleFile -Raw | ConvertFrom-Json
            $floorLaunch = $null
            if ($null -ne $swapTarget -and $s.id -eq $swapTarget.id -and $null -ne $targetRuntimeFloor -and $targetRuntimeFloor.Ok) {
                $floorLaunch = $targetRuntimeFloor.Launch
            }
            $chainLine = Get-ModelChainLine -Seat $s -FloorLaunch $floorLaunch
            if ($roleJson.prompt -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
                $roleJson.prompt = Replace-LiteralRegex -InputText $roleJson.prompt -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $chainLine
                Save-SeatMap -Map $roleJson -Path $roleFile
                Write-Host "  Updated role for $($s.codename) ($($s.name))" -ForegroundColor Green
            } else {
                $msg = "Could not find Model chain line in role for $($s.codename)"
                $syncMisses.Add($msg)
                Write-Warning "  $msg"
            }
        }
    }
}

if ($SyncNotes -or $All) {
    Write-Host "`n=== Syncing Canvas Notes ===" -ForegroundColor Cyan
    $resolvedWorkspace = Resolve-MaestriWorkspaceId -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
    $notesDir = Join-Path $HOME '.maestri' 'workspaces' $resolvedWorkspace 'notes'
    if (-not (Test-Path -LiteralPath $notesDir)) {
        $syncMisses.Add("Notes directory not found at: $notesDir")
        Write-Warning "Notes directory not found at: $notesDir"
    } else {
        $charterPath = Join-Path $notesDir 'harness-team-charter.md'
        if (-not (Test-Path -LiteralPath $charterPath)) {
            $syncMisses.Add("harness-team-charter.md not found at: $charterPath")
            Write-Warning "  harness-team-charter.md not found"
        } else {
            $charterContent = Get-Content -LiteralPath $charterPath -Raw
            $rosterTable = @(
                '| Seat | Codename | Agent + model (active) | Pool |',
                '|---|---|---|---|'
            )
            foreach ($s in @($seatMap.seats)) {
                $runtimeFloor = $null
                if ($null -ne $swapTarget -and $s.id -eq $swapTarget.id) { $runtimeFloor = $targetRuntimeFloor }
                $activeCell = Get-SeatActiveLaunchCell -Seat $s -RuntimeFloor $runtimeFloor
                $rosterTable += "| $($s.name) | $($s.codename) | $($activeCell.launch) | $($activeCell.pool) |"
            }
            $newRoster = ($rosterTable -join "`n")
            if ($charterContent -match $rosterHeaderPattern) {
                $charterContent = Replace-LiteralRegex -InputText $charterContent -Pattern $rosterHeaderPattern -Replacement "$newRoster`n`n"
                Save-Utf8NoBom -Path $charterPath -Content $charterContent
                Write-Host '  Updated Roster table in harness-team-charter.md' -ForegroundColor Green
            } else {
                $msg = 'Could not find Roster table in harness-team-charter.md'
                $syncMisses.Add($msg)
                Write-Warning "  $msg"
            }
        }

        $restartPath = Join-Path $notesDir 'team-restart.md'
        if (-not (Test-Path -LiteralPath $restartPath)) {
            $syncMisses.Add("team-restart.md not found at: $restartPath")
            Write-Warning "  team-restart.md not found"
        } else {
            $restartContent = Get-Content -LiteralPath $restartPath -Raw
            $launchTable = @(
                '| Seat | Launch command |',
                '| --- | --- |'
            )
            foreach ($s in @($seatMap.seats)) {
                $runtimeFloor = $null
                if ($null -ne $swapTarget -and $s.id -eq $swapTarget.id) { $runtimeFloor = $targetRuntimeFloor }
                $activeCell = Get-SeatActiveLaunchCell -Seat $s -RuntimeFloor $runtimeFloor
                $launchTable += "| $($s.codename) | ``$($activeCell.launch)`` |"
            }
            $newLaunch = ($launchTable -join "`n")
            if ($restartContent -match $launchHeaderPattern) {
                $restartContent = Replace-LiteralRegex -InputText $restartContent -Pattern $launchHeaderPattern -Replacement "$newLaunch`n`n"
                Save-Utf8NoBom -Path $restartPath -Content $restartContent
                Write-Host '  Updated Launch commands table in team-restart.md' -ForegroundColor Green
            } else {
                $msg = 'Could not find Launch commands table in team-restart.md'
                $syncMisses.Add($msg)
                Write-Warning "  $msg"
            }
        }
    }
}

if ($Verify -or $All) {
    Write-Host "`n=== Verifying Against Active Maestri Workspace ===" -ForegroundColor Cyan
    $resolvedWorkspace = Resolve-MaestriWorkspaceId -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
    $wsPath = Join-Path $HOME '.maestri' 'workspaces' $resolvedWorkspace 'workspace.json'
    if (-not (Test-Path -LiteralPath $wsPath)) {
        Write-Warning "workspace.json not found at: $wsPath"
    } else {
        $ws = Get-Content -LiteralPath $wsPath -Raw | ConvertFrom-Json
        $terminals = @()
        if ((Test-JsonProperty -Object $ws -Name 'payload') -and (Test-JsonProperty -Object $ws.payload -Name 'nodes')) {
            $terminals = @(
                $ws.payload.nodes |
                    Where-Object { Test-JsonProperty -Object $_.content -Name 'terminal' } |
                    ForEach-Object { $_.content.terminal._0 }
            )
        }
        $driftCount = 0
        foreach ($s in @($seatMap.seats)) {
            $runtimeFloor = $null
            if ($null -ne $swapTarget -and $s.id -eq $swapTarget.id) { $runtimeFloor = $targetRuntimeFloor }
            $activeKey = Get-SeatActiveRungName -Seat $s
            $activeCell = Get-SeatActiveLaunchCell -Seat $s -RuntimeFloor $runtimeFloor
            $t = @(
                $terminals | Where-Object {
                    (Test-JsonProperty -Object $_ -Name 'assignedRoleId') -and $_.assignedRoleId -eq $s.roleId
                }
            ) | Select-Object -First 1
            if ($null -eq $t) { continue }
            $terminalCmd = if (Test-JsonProperty -Object $t -Name 'command') { [string]$t.command } else { '' }
            if ($terminalCmd -ne $activeCell.launch) {
                $driftCount++
                Write-Warning "DRIFT on $($s.codename) ($($s.name)):"
                Write-Host "   Map activeRung ($activeKey): $($activeCell.launch)" -ForegroundColor Yellow
                Write-Host "   Workspace terminal:          $terminalCmd" -ForegroundColor Red
            } else {
                Write-Host "  [MATCH] $($s.codename): $($activeCell.launch)" -ForegroundColor Green
            }
        }
        if ($driftCount -eq 0) {
            Write-Host 'All seats MATCH current workspace.json!' -ForegroundColor Green
        } else {
            Write-Warning "Found $driftCount seats with drift between seat-map.json and workspace.json."
        }
    }
}

if ($syncMisses.Count -gt 0) {
    $noteFatal = @(
        $syncMisses | Where-Object {
            $_ -match 'Notes directory not found|harness-team-charter|team-restart|Roster table|Launch commands table'
        }
    )
    # Target-swap notes miss: restore map/role/notes/swap-log (B1/A7). Missing
    # other seats' role files stay non-fatal for a committed target swap (A9).
    if ($null -ne $swapTarget -and $noteFatal.Count -eq 0) {
        foreach ($m in $syncMisses) { Write-Warning ([string]$m) }
        exit 0
    }
    Restore-SwapRollback
    Write-ViolationsAndExit -Violations @($syncMisses)
}

exit 0
