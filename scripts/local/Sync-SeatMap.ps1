<#
.SYNOPSIS
    Four-way synchronizer for Maestri seat assignments (seat-map.json).
.DESCRIPTION
    Propagates the active rung from scripts/local/seat-map.json across:
    1. Role prompts (.maestri/roles/*/role.json) — all three rungs
    2. Canvas Note 1 (harness-team-charter.md roster table)
    3. Canvas Note 2 (team-restart.md launch commands)
    4. Printed `maestri recruit --replace` commands (-GenerateCommands)

    Runtime contract is `activeRung` (head|then|floor), the same field the
    portal writes. Invariant violations always exit 1 (Quill ZEN-floor
    exception matches Test-SeatMap.ps1).
.PARAMETER SeatMapPath
    Path to seat-map.json.
.PARAMETER Seat
    Seat id or codename to update.
.PARAMETER Rung
    Active rung to set: head, then, floor.
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
.PARAMETER All
    Validate, print recruit commands, and sync roles and notes.
#>
[CmdletBinding()]
param(
    [string]$SeatMapPath = (Join-Path $PSScriptRoot 'seat-map.json'),
    [string]$Seat,
    [ValidateSet('head', 'then', 'floor')]
    [string]$Rung,
    [string]$WorkspaceId,
    [switch]$SyncRoles,
    [switch]$SyncNotes,
    [switch]$Verify,
    [switch]$GenerateCommands,
    [switch]$Validate,
    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_seat-map.ps1')

if (-not (Test-Path -LiteralPath $SeatMapPath)) {
    throw "Seat map file not found at: $SeatMapPath"
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
$seatMap = Get-Content -LiteralPath $SeatMapPath -Raw | ConvertFrom-Json

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

function Get-ActiveRungName {
    param($SeatObj)
    if ((Test-JsonProperty -Object $SeatObj -Name 'activeRung') -and -not [string]::IsNullOrWhiteSpace([string]$SeatObj.activeRung)) {
        return [string]$SeatObj.activeRung
    }
    return 'head'
}

function Save-SeatMap {
    param($Map, [string]$Path)
    $json = $Map | ConvertTo-Json -Depth 12
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    Save-Utf8NoBom -Path $Path -Content $json
}

$violations = @(Get-SeatMapViolations -Map $seatMap)
$noAction = -not ($Seat -or $SyncRoles -or $SyncNotes -or $Verify -or $GenerateCommands -or $All)
if ($Validate -or $All -or $noAction) {
    Write-Host '=== Validating Seat Map Invariants ===' -ForegroundColor Cyan
    Write-ViolationsAndExit -Violations $violations
    Write-Host 'All charter invariants PASSED:' -ForegroundColor Green
    Write-Host '  [OK] At most 2 Cursor heads'
    Write-Host '  [OK] At most 1 AGY-G head'
    Write-Host '  [OK] At least 1 Gemini API head'
    Write-Host '  [OK] Zen floor = 0 (Quill excepted)'
    Write-Host '  [OK] 3 distinct pools per seat'
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
    $target = Get-SeatByName -Map $seatMap -Name $Seat
    if ($null -eq $target) {
        throw "Seat '$Seat' not found in seat map."
    }
    $target.activeRung = $Rung
    $after = @(Get-SeatMapViolations -Map $seatMap)
    Write-ViolationsAndExit -Violations $after
    Save-SeatMap -Map $seatMap -Path $SeatMapPath
    Write-Host "Updated seat '$($target.codename)' activeRung to '$Rung'." -ForegroundColor Green
}

if ($GenerateCommands -or $All) {
    Write-Host "`n=== Maestri Replacement Commands (maestri recruit --replace) ===" -ForegroundColor Cyan
    foreach ($s in @($seatMap.seats)) {
        $activeKey = Get-ActiveRungName -SeatObj $s
        $activeCell = $s.rungs.$activeKey
        Write-Host "maestri recruit `"$($s.codename)`" --preset `"$($s.preset)`" --command `"$($activeCell.launch)`" --replace `"$($s.codename)`""
    }
}

if ($SyncRoles -or $All) {
    Write-Host "`n=== Syncing Role Prompts (.maestri/roles/) ===" -ForegroundColor Cyan
    $rolesDir = Join-Path $repoRoot '.maestri' 'roles'
    if (Test-Path -LiteralPath $rolesDir) {
        foreach ($s in @($seatMap.seats)) {
            $roleFile = Join-Path $rolesDir $s.roleId 'role.json'
            if (-not (Test-Path -LiteralPath $roleFile)) {
                Write-Warning "  Role file not found: $roleFile"
                continue
            }
            $roleJson = Get-Content -LiteralPath $roleFile -Raw | ConvertFrom-Json
            $chainLine = Get-ModelChainLine -Seat $s
            if ($roleJson.prompt -match 'Model chain \(best first\):.+?\(FLOOR\)\.') {
                $roleJson.prompt = Replace-LiteralRegex -InputText $roleJson.prompt -Pattern 'Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $chainLine
                Save-SeatMap -Map $roleJson -Path $roleFile
                Write-Host "  Updated role for $($s.codename) ($($s.name))" -ForegroundColor Green
            } else {
                Write-Warning "  Could not find Model chain line in role for $($s.codename)"
            }
        }
    } else {
        Write-Warning "Roles directory not found at: $rolesDir"
    }
}

if ($SyncNotes -or $All) {
    Write-Host "`n=== Syncing Canvas Notes ===" -ForegroundColor Cyan
    $resolvedWorkspace = Resolve-MaestriWorkspaceId -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
    $notesDir = Join-Path $HOME '.maestri' 'workspaces' $resolvedWorkspace 'notes'
    if (-not (Test-Path -LiteralPath $notesDir)) {
        Write-Warning "Notes directory not found at: $notesDir"
    } else {
        $charterPath = Join-Path $notesDir 'harness-team-charter.md'
        if (Test-Path -LiteralPath $charterPath) {
            $charterContent = Get-Content -LiteralPath $charterPath -Raw
            $rosterTable = @(
                '| Seat | Codename | Agent + model (head) | Pool |',
                '|---|---|---|---|'
            )
            foreach ($s in @($seatMap.seats)) {
                $activeKey = Get-ActiveRungName -SeatObj $s
                $activeCell = $s.rungs.$activeKey
                $rosterTable += "| $($s.name) | $($s.codename) | $($activeCell.launch) | $($activeCell.pool) |"
            }
            $newRoster = ($rosterTable -join "`n")
            if ($charterContent -match '(?ms)\| Seat \| Codename \| Agent \+ model \(head\) \| Pool \|.+?\n\n') {
                $charterContent = Replace-LiteralRegex -InputText $charterContent -Pattern '(?ms)\| Seat \| Codename \| Agent \+ model \(head\) \| Pool \|.+?\n\n' -Replacement "$newRoster`n`n"
                Save-Utf8NoBom -Path $charterPath -Content $charterContent
                Write-Host '  Updated Roster table in harness-team-charter.md' -ForegroundColor Green
            } else {
                Write-Warning '  Could not find Roster table in harness-team-charter.md'
            }
        }

        $restartPath = Join-Path $notesDir 'team-restart.md'
        if (Test-Path -LiteralPath $restartPath) {
            $restartContent = Get-Content -LiteralPath $restartPath -Raw
            $launchTable = @(
                '| Seat | Launch command |',
                '| --- | --- |'
            )
            foreach ($s in @($seatMap.seats)) {
                $activeKey = Get-ActiveRungName -SeatObj $s
                $activeCell = $s.rungs.$activeKey
                $launchTable += "| $($s.codename) | ``$($activeCell.launch)`` |"
            }
            $newLaunch = ($launchTable -join "`n")
            if ($restartContent -match '(?ms)\| Seat \| Launch command \|.+?\n\n') {
                $restartContent = Replace-LiteralRegex -InputText $restartContent -Pattern '(?ms)\| Seat \| Launch command \|.+?\n\n' -Replacement "$newLaunch`n`n"
                Save-Utf8NoBom -Path $restartPath -Content $restartContent
                Write-Host '  Updated Launch commands table in team-restart.md' -ForegroundColor Green
            } else {
                Write-Warning '  Could not find Launch commands table in team-restart.md'
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
            $activeKey = Get-ActiveRungName -SeatObj $s
            $activeCell = $s.rungs.$activeKey
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

exit 0
