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
    Read-only drift check of each seat-map head launch against workspace.json
    terminals. Exit 1 on drift, missing/duplicate terminals, or workspace errors.
    Cannot be combined with -Seat/-Rung; use -All for write/sync then verify.
    Not a merge-bar gate.
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
    [switch]$All,
    [string]$RolesDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_seat-map.ps1')

function Invoke-StaleHaltScrub {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # Shared stale-halt scrub contract (DEV-269): remove the obsolete model-chain
    # membership self-validation instruction. Anchor literal is
    # "Halt and report only if it appears nowhere in it." — when present, also
    # remove the preceding "You are at or above your floor..." sentence that forms
    # the same validation rule. Preserve unrelated floor-quality guidance
    # ("Do not compare yourself against the floor entry alone...") and duties.
    $patternCombined = 'You are at or above your floor if the model you are running appears\s+\*\*anywhere in that chain\*\*\.\s+Halt and report only if it appears nowhere in it\.\s*'
    $scrubbed = [regex]::Replace($Text, $patternCombined, '')
    if ($scrubbed.Contains('Halt and report only if it appears nowhere in it.')) {
        $patternSolo = '\s*Halt and report only if it appears nowhere in it\.\s*'
        $scrubbed = [regex]::Replace($scrubbed, $patternSolo, ' ')
    }
    return $scrubbed
}

function Test-StaleHaltPresent {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text.Contains('Halt and report only if it appears nowhere in it.')
}

if ($Verify -and -not $All -and (-not [string]::IsNullOrWhiteSpace($Seat) -or -not [string]::IsNullOrWhiteSpace($Rung))) {
    Write-Error '-Verify cannot be combined with -Seat/-Rung because -Verify is read-only. Use -All for write/sync then verify.' -ErrorAction Continue
    exit 1
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
if ([string]::IsNullOrWhiteSpace($RolesDir)) {
    $RolesDir = Join-Path $repoRoot '.maestri' 'roles'
}
$resolvedMap = Resolve-LiveSeatMapPath -SeatMapPath $SeatMapPath -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
$SeatMapPath = $resolvedMap.Path
$resolvedWorkspaceId = [string]$resolvedMap.WorkspaceId

if ($Init) {
    if (-not $resolvedMap.Ok) {
        Write-SeatMapResolutionFailureMessage -ResolverError ([string]$resolvedMap.Error)
        exit 1
    }
    $examplePath = Get-SeatMapExamplePath
    if (-not (Test-Path -LiteralPath $examplePath)) {
        Write-Error "Seat map example not found at: $examplePath" -ErrorAction Continue
        exit 1
    }
    $mapLock = Enter-SeatMapProcessLock -SeatMapPath $SeatMapPath
    try {
        if (Test-Path -LiteralPath $SeatMapPath) {
            Write-Error "Refusing -Init: target already exists at: $SeatMapPath" -ErrorAction Continue
            exit 1
        }
        Write-Host 'Creating from example; not restoring previous state. Swap log: ~/.maestri/seat-map-swaps.jsonl'
        $swapLogPath = Join-Path $HOME '.maestri' 'seat-map-swaps.jsonl'
        if ((Test-Path -LiteralPath $swapLogPath) -and ((Get-Item -LiteralPath $swapLogPath).Length -gt 0)) {
            Write-Warning "Swap log is non-empty at $swapLogPath; -Init copies the example and does not restore previous state."
        }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $exampleContent = [System.IO.File]::ReadAllText($examplePath, $utf8)
        Save-SeatMapFile -Path $SeatMapPath -Content $exampleContent
        exit 0
    }
    finally {
        Exit-SeatMapProcessLock -Handle $mapLock
    }
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
$preflightNotes = $null

function Write-ViolationsAndExit {
    param([object[]]$Violations)
    # Redirected Write-Error + exit inside a function drops stderr on Ubuntu.
    Write-SeatMapViolationsAndExit -Violations $Violations
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
        [string]$RepoRootParam,
        [string]$SeatMapPathParam
    )
    # Notes live beside seat-map.json in the workspace dir. Prefer that sibling
    # when present so portal Sync still finds them if Start-Process dropped HOME.
    if (-not [string]::IsNullOrWhiteSpace($SeatMapPathParam) -and (Test-Path -LiteralPath $SeatMapPathParam)) {
        $mapDir = [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $SeatMapPathParam).Path)
        if (-not [string]::IsNullOrWhiteSpace($mapDir)) {
            $sibling = Join-Path $mapDir 'notes'
            if (Test-Path -LiteralPath $sibling) {
                return [pscustomobject]@{
                    NotesDir    = $sibling
                    CharterPath = Join-Path $sibling 'harness-team-charter.md'
                    RestartPath = Join-Path $sibling 'team-restart.md'
                }
            }
        }
    }
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

function Get-VerifyNormalizedCommand {
    param([AllowNull()][string]$Command)
    if ($null -eq $Command) { return '' }
    return [regex]::Replace([string]$Command, '[\r\n]+$', '')
}

function Get-VerifySha256Hex {
    param([AllowNull()][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Value))
        return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Write-VerifyReceiptIfAll {
    if ($All) {
        [Console]::Error.WriteLine('Sync phases completed before verify failure; workspace drift remains.')
    }
}

function Get-WorkspaceTerminalParseResult {
    param($Workspace)
    $records = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-JsonProperty -Object $Workspace -Name 'payload')) {
        return [pscustomobject]@{ Malformed = $false; Records = @() }
    }
    $payload = $Workspace.payload
    if (-not (Test-JsonProperty -Object $payload -Name 'nodes') -or $null -eq $payload.nodes) {
        return [pscustomobject]@{ Malformed = $false; Records = @() }
    }

    foreach ($node in @($payload.nodes)) {
        if ($null -eq $node) { continue }
        if (-not (Test-JsonProperty -Object $node -Name 'content')) { continue }
        $content = $node.content
        if ($null -eq $content -or -not (Test-JsonProperty -Object $content -Name 'terminal')) { continue }
        $terminal = $content.terminal
        if ($null -eq $terminal -or -not (Test-JsonProperty -Object $terminal -Name '_0')) {
            return [pscustomobject]@{ Malformed = $true; Records = @() }
        }
        $t0 = $terminal._0
        if ($null -eq $t0) {
            return [pscustomobject]@{ Malformed = $true; Records = @() }
        }
        $hasRole = Test-JsonProperty -Object $t0 -Name 'assignedRoleId'
        $hasCommand = Test-JsonProperty -Object $t0 -Name 'command'
        $roleId = if ($hasRole) { [string]$t0.assignedRoleId } else { '' }
        if (-not $hasRole -or [string]::IsNullOrEmpty($roleId)) {
            # Unassigned operator terminal (command, no assignedRoleId): skip.
            # Assigned seat terminals still require command; empty _0 stays fatal.
            if ($hasCommand) { continue }
            return [pscustomobject]@{ Malformed = $true; Records = @() }
        }
        if (-not $hasCommand) {
            return [pscustomobject]@{ Malformed = $true; Records = @() }
        }
        $records.Add([pscustomobject]@{
            AssignedRoleId = $roleId
            Command        = [string]$t0.command
        })
    }

    return [pscustomobject]@{
        Malformed = $false
        Records   = @($records)
    }
}

function Invoke-SeatMapWorkspaceVerify {
    param(
        $Map,
        [string]$WorkspaceIdParam,
        [string]$ResolvedWorkspaceIdParam,
        [string]$RepoRootParam
    )

    Write-Host "`n=== Verifying Against Active Maestri Workspace ===" -ForegroundColor Cyan

    $wsId = $ResolvedWorkspaceIdParam
    if ([string]::IsNullOrWhiteSpace($wsId)) {
        $wsId = $WorkspaceIdParam
    }
    if ([string]::IsNullOrWhiteSpace($wsId)) {
        try {
            $wsId = Resolve-MaestriWorkspaceId -WorkspaceId $WorkspaceIdParam -RepoRoot $RepoRootParam
        }
        catch {
            Write-SeatMapResolutionFailureMessage -ResolverError ([string]$_.Exception.Message)
            return $false
        }
    }

    $wsPath = Join-Path $HOME '.maestri' 'workspaces' $wsId 'workspace.json'
    if (-not (Test-Path -LiteralPath $wsPath)) {
        [Console]::Error.WriteLine("Verify workspace.json not found for workspaceId=$wsId")
        return $false
    }

    $ws = $null
    try {
        $raw = Get-Content -LiteralPath $wsPath -Raw -ErrorAction Stop
        $ws = $raw | ConvertFrom-Json
    }
    catch {
        [Console]::Error.WriteLine("Verify workspace.json unreadable for workspaceId=$wsId")
        return $false
    }
    if ($null -eq $ws) {
        [Console]::Error.WriteLine("Verify workspace.json unreadable for workspaceId=$wsId")
        return $false
    }

    $parsed = Get-WorkspaceTerminalParseResult -Workspace $ws
    if ($parsed.Malformed) {
        [Console]::Error.WriteLine('[VERIFY ERROR] workspace terminal payload malformed')
        return $false
    }
    $records = @($parsed.Records)
    if ($records.Count -eq 0) {
        [Console]::Error.WriteLine('[VERIFY ERROR] no terminal records found in workspace.json')
        return $false
    }

    $issueCount = 0
    $matchCount = 0
    foreach ($s in @($Map.seats)) {
        $codeName = if (Test-JsonProperty -Object $s -Name 'codename') { [string]$s.codename } else { [string]$s.id }
        $roleId = if (Test-JsonProperty -Object $s -Name 'roleId') { [string]$s.roleId } else { '' }
        $headCell = Get-SeatMapRungByRole -Seat $s -Role 'head'
        $expected = ''
        if ($null -ne $headCell -and (Test-JsonProperty -Object $headCell -Name 'launch')) {
            $expected = [string]$headCell.launch
        }

        $hits = @(
            $records | Where-Object { $_.AssignedRoleId -eq $roleId }
        )
        if ($hits.Count -eq 0) {
            $issueCount++
            [Console]::Error.WriteLine("[VERIFY MISSING] $codeName roleId=$roleId no terminal with assignedRoleId")
            continue
        }
        if ($hits.Count -gt 1) {
            $issueCount++
            [Console]::Error.WriteLine("[VERIFY ERROR] $codeName roleId=$roleId duplicate terminals for assignedRoleId")
            continue
        }

        $actual = Get-VerifyNormalizedCommand -Command $hits[0].Command
        if ($actual -cne $expected) {
            $issueCount++
            $expectedHash = Get-VerifySha256Hex -Value $expected
            $actualHash = Get-VerifySha256Hex -Value $actual
            [Console]::Error.WriteLine("[VERIFY DRIFT] $codeName roleId=$roleId head expectedSha256=$expectedHash actualSha256=$actualHash")
            continue
        }

        $matchCount++
        $matchHash = Get-VerifySha256Hex -Value $expected
        [Console]::Out.WriteLine("[VERIFY MATCH] $codeName roleId=$roleId head sha256=$matchHash")
    }

    if ($issueCount -gt 0) {
        [Console]::Error.WriteLine("VERIFY FAILED: $issueCount issue(s); workspaceId=$wsId")
        return $false
    }

    [Console]::Out.WriteLine("VERIFY OK: $matchCount seat(s) matched; workspaceId=$wsId")
    return $true
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

    $rolesDirForSwap = $RolesDir
    $swapRoleFile = Join-Path $rolesDirForSwap $swapTarget.roleId 'role.json'
    $swapRoleJson = $null
    $swapChainLine = $null
    $swapAgentsFile = Join-Path $rolesDirForSwap $swapTarget.roleId 'AGENTS.md'
    $swapClaudeFile = Join-Path $rolesDirForSwap $swapTarget.roleId 'CLAUDE.md'
    $swapAgentsContent = $null
    $swapClaudeContent = $null
    if (Test-Path -LiteralPath $swapRoleFile) {
        $swapRoleJson = Get-Content -LiteralPath $swapRoleFile -Raw | ConvertFrom-Json
        $swapChainLine = Get-ModelChainLine -Seat $swapTarget -FloorLaunch $targetRuntimeFloor.Launch
        if ($swapRoleJson.prompt -notmatch '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
            Write-Error "Seat '$($swapTarget.codename)' role file has no Model chain line; refusing target swap before writes." -ErrorAction Continue
            exit 1
        }
        $swapRoleJson.prompt = Replace-LiteralRegex -InputText $swapRoleJson.prompt -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $swapChainLine
        $swapRoleJson.prompt = Invoke-StaleHaltScrub -Text $swapRoleJson.prompt
        if (Test-StaleHaltPresent -Text $swapRoleJson.prompt) {
            Write-Error "Seat '$($swapTarget.codename)' role file still contains stale halt text after scrub; refusing target swap before writes." -ErrorAction Continue
            exit 1
        }
    }
    # Preflight scrub for optional AGENTS.md/CLAUDE.md (missing is non-fatal)
    if (Test-Path -LiteralPath $swapAgentsFile) {
        $swapAgentsContent = Get-Content -LiteralPath $swapAgentsFile -Raw
        $swapAgentsScrubbed = Invoke-StaleHaltScrub -Text $swapAgentsContent
        if ($swapAgentsScrubbed -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
            $swapChainLineForMd = if ($null -ne $swapChainLine) { $swapChainLine } else { Get-ModelChainLine -Seat $swapTarget -FloorLaunch $targetRuntimeFloor.Launch }
            $swapAgentsScrubbed = Replace-LiteralRegex -InputText $swapAgentsScrubbed -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $swapChainLineForMd
        }
        if (Test-StaleHaltPresent -Text $swapAgentsScrubbed) {
            Write-Error "Seat '$($swapTarget.codename)' AGENTS.md still contains stale halt text after scrub; refusing target swap before writes." -ErrorAction Continue
            exit 1
        }
    }
    if (Test-Path -LiteralPath $swapClaudeFile) {
        $swapClaudeContent = Get-Content -LiteralPath $swapClaudeFile -Raw
        $swapClaudeScrubbed = Invoke-StaleHaltScrub -Text $swapClaudeContent
        if ($swapClaudeScrubbed -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
            $swapChainLineForMd = if ($null -ne $swapChainLine) { $swapChainLine } else { Get-ModelChainLine -Seat $swapTarget -FloorLaunch $targetRuntimeFloor.Launch }
            $swapClaudeScrubbed = Replace-LiteralRegex -InputText $swapClaudeScrubbed -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $swapChainLineForMd
        }
        if (Test-StaleHaltPresent -Text $swapClaudeScrubbed) {
            Write-Error "Seat '$($swapTarget.codename)' CLAUDE.md still contains stale halt text after scrub; refusing target swap before writes." -ErrorAction Continue
            exit 1
        }
    }

    if ($SyncNotes -or $All) {
        try {
            $preflightNotes = Get-TargetSwapNotePaths -WorkspaceIdParam $WorkspaceId -RepoRootParam $repoRoot -SeatMapPathParam $SeatMapPath
        } catch {
            Write-Error ([string]$_) -ErrorAction Continue
            exit 1
        }
        Write-ViolationsAndExit -Violations @(Get-TargetSwapNoteMisses -NotePaths $preflightNotes)
    }

    $mapLock = Enter-SeatMapProcessLock -SeatMapPath $SeatMapPath
    try {
        $seatMap = Get-Content -LiteralPath $SeatMapPath -Raw | ConvertFrom-Json
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
        $lockedDecision = Get-SeatMapTargetSwapDecision -Seat $swapTarget -RungName $Rung -RuntimeFloor $targetRuntimeFloor
        $swapTarget.activeRung = $Rung
        Write-ViolationsAndExit -Violations @(Get-SeatMapViolations -Map $seatMap)

        $swapRoleJson = $null
        $swapChainLine = $null
        $swapAgentsContentLocked = $null
        $swapClaudeContentLocked = $null
        $swapAgentsScrubbedLocked = $null
        $swapClaudeScrubbedLocked = $null
        $swapAgentsFileLocked = Join-Path $RolesDir $swapTarget.roleId 'AGENTS.md'
        $swapClaudeFileLocked = Join-Path $RolesDir $swapTarget.roleId 'CLAUDE.md'
        if (Test-Path -LiteralPath $swapRoleFile) {
            $swapRoleJson = Get-Content -LiteralPath $swapRoleFile -Raw | ConvertFrom-Json
            $swapChainLine = Get-ModelChainLine -Seat $swapTarget -FloorLaunch $targetRuntimeFloor.Launch
            if ($swapRoleJson.prompt -notmatch '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
                Write-Error "Seat '$($swapTarget.codename)' role file has no Model chain line; refusing target swap before writes." -ErrorAction Continue
                exit 1
            }
            $swapRoleJson.prompt = Replace-LiteralRegex -InputText $swapRoleJson.prompt -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $swapChainLine
            $swapRoleJson.prompt = Invoke-StaleHaltScrub -Text $swapRoleJson.prompt
            if (Test-StaleHaltPresent -Text $swapRoleJson.prompt) {
                Write-Error "Seat '$($swapTarget.codename)' role file still contains stale halt text after scrub; refusing target swap before writes." -ErrorAction Continue
                exit 1
            }
        }
        if (Test-Path -LiteralPath $swapAgentsFileLocked) {
            $swapAgentsContentLocked = Get-Content -LiteralPath $swapAgentsFileLocked -Raw
            $swapAgentsScrubbedLocked = Invoke-StaleHaltScrub -Text $swapAgentsContentLocked
            $swapChainLineForMd = if ($null -ne $swapChainLine) { $swapChainLine } else { Get-ModelChainLine -Seat $swapTarget -FloorLaunch $targetRuntimeFloor.Launch }
            if ($swapAgentsScrubbedLocked -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
                $swapAgentsScrubbedLocked = Replace-LiteralRegex -InputText $swapAgentsScrubbedLocked -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $swapChainLineForMd
            }
            $swapAgentsScrubbedLocked = Invoke-StaleHaltScrub -Text $swapAgentsScrubbedLocked
            if (Test-StaleHaltPresent -Text $swapAgentsScrubbedLocked) {
                Write-Error "Seat '$($swapTarget.codename)' AGENTS.md still contains stale halt text after scrub; refusing target swap before writes." -ErrorAction Continue
                exit 1
            }
        }
        if (Test-Path -LiteralPath $swapClaudeFileLocked) {
            $swapClaudeContentLocked = Get-Content -LiteralPath $swapClaudeFileLocked -Raw
            $swapClaudeScrubbedLocked = Invoke-StaleHaltScrub -Text $swapClaudeContentLocked
            $swapChainLineForMd = if ($null -ne $swapChainLine) { $swapChainLine } else { Get-ModelChainLine -Seat $swapTarget -FloorLaunch $targetRuntimeFloor.Launch }
            if ($swapClaudeScrubbedLocked -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
                $swapClaudeScrubbedLocked = Replace-LiteralRegex -InputText $swapClaudeScrubbedLocked -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $swapChainLineForMd
            }
            $swapClaudeScrubbedLocked = Invoke-StaleHaltScrub -Text $swapClaudeScrubbedLocked
            if (Test-StaleHaltPresent -Text $swapClaudeScrubbedLocked) {
                Write-Error "Seat '$($swapTarget.codename)' CLAUDE.md still contains stale halt text after scrub; refusing target swap before writes." -ErrorAction Continue
                exit 1
            }
        }

        $script:swapRollback = [ordered]@{}
        Add-SwapRollbackPath -Path $SeatMapPath
        Add-SwapRollbackPath -Path $swapRoleFile
        Add-SwapRollbackPath -Path $swapAgentsFileLocked
        Add-SwapRollbackPath -Path $swapClaudeFileLocked
        if ($SyncRoles -or $All) {
            $rolesDirForRollback = $RolesDir
            foreach ($s in @($seatMap.seats)) {
                if (Test-JsonProperty -Object $s -Name 'roleId') {
                    Add-SwapRollbackPath -Path (Join-Path $rolesDirForRollback $s.roleId 'role.json')
                    Add-SwapRollbackPath -Path (Join-Path $rolesDirForRollback $s.roleId 'AGENTS.md')
                    Add-SwapRollbackPath -Path (Join-Path $rolesDirForRollback $s.roleId 'CLAUDE.md')
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
        if ($null -ne $swapAgentsScrubbedLocked -and $swapAgentsScrubbedLocked -ne $swapAgentsContentLocked) {
            Save-Utf8NoBom -Path $swapAgentsFileLocked -Content $swapAgentsScrubbedLocked
        }
        if ($null -ne $swapClaudeScrubbedLocked -and $swapClaudeScrubbedLocked -ne $swapClaudeContentLocked) {
            Save-Utf8NoBom -Path $swapClaudeFileLocked -Content $swapClaudeScrubbedLocked
        }
        [Console]::Out.WriteLine((Format-SeatMapLockedSwapLine -Decision $lockedDecision))
        Write-Host "Updated seat '$($swapTarget.codename)' activeRung to '$Rung'." -ForegroundColor Green
        if ($null -ne $swapRoleJson) {
            Write-Host "  Updated role model-chain FLOOR for $($swapTarget.codename) to runtime floor '$($targetRuntimeFloor.Launch)'." -ForegroundColor Green
        }
    }
    finally {
        Exit-SeatMapProcessLock -Handle $mapLock
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
    $rolesDir = $RolesDir
    if (-not (Test-Path -LiteralPath $rolesDir)) {
        $syncMisses.Add("Roles directory not found at: $rolesDir")
        Write-Warning "Roles directory not found at: $rolesDir"
    } else {
        $syncSnapshot = @{}
        foreach ($s in @($seatMap.seats)) {
            if (-not (Test-JsonProperty -Object $s -Name 'roleId')) { continue }
            foreach ($fname in @('role.json', 'AGENTS.md', 'CLAUDE.md')) {
                $p = Join-Path $rolesDir $s.roleId $fname
                if (Test-Path -LiteralPath $p) {
                    $syncSnapshot[$p] = [System.IO.File]::ReadAllBytes($p)
                }
            }
        }
        $syncFatal = $null
        try {
            foreach ($s in @($seatMap.seats)) {
                $roleFile = Join-Path $rolesDir $s.roleId 'role.json'
                $agentsFile = Join-Path $rolesDir $s.roleId 'AGENTS.md'
                $claudeFile = Join-Path $rolesDir $s.roleId 'CLAUDE.md'
                $floorLaunch = $null
                if ($null -ne $swapTarget -and $s.id -eq $swapTarget.id -and $null -ne $targetRuntimeFloor -and $targetRuntimeFloor.Ok) {
                    $floorLaunch = $targetRuntimeFloor.Launch
                }
                $chainLine = Get-ModelChainLine -Seat $s -FloorLaunch $floorLaunch
                $roleHandled = $false
                $roleHasChain = $false
                if (-not (Test-Path -LiteralPath $roleFile)) {
                    $msg = "Role file not found for $($s.codename): $roleFile"
                    $syncMisses.Add($msg)
                    Write-Warning "  $msg"
                } else {
                    $roleJson = Get-Content -LiteralPath $roleFile -Raw | ConvertFrom-Json
                    if ($roleJson.prompt -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
                        $roleJson.prompt = Replace-LiteralRegex -InputText $roleJson.prompt -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $chainLine
                        $roleHasChain = $true
                    } else {
                        $msg = "Could not find Model chain line in role for $($s.codename)"
                        $syncMisses.Add($msg)
                        Write-Warning "  $msg"
                    }
                    $roleJson.prompt = Invoke-StaleHaltScrub -Text $roleJson.prompt
                    if (Test-StaleHaltPresent -Text $roleJson.prompt) {
                        throw "Seat '$($s.codename)' role file still contains stale halt text after scrub; refusing sync."
                    }
                    if ($roleHasChain) {
                        Save-SeatMap -Map $roleJson -Path $roleFile
                        Write-Host "  Updated role for $($s.codename) ($($s.name))" -ForegroundColor Green
                        $roleHandled = $true
                    } else {
                        # Even when chain missing, if scrub changed content, persist it so stale does not survive; still report syncMiss for missing chain
                        $origRaw = Get-Content -LiteralPath $roleFile -Raw
                        $origJson = $origRaw | ConvertFrom-Json
                        $origPrompt = [string]$origJson.prompt
                        $scrubbedPrompt = Invoke-StaleHaltScrub -Text $origPrompt
                        if ($scrubbedPrompt -ne $origPrompt) {
                            $roleJson.prompt = $scrubbedPrompt
                            Save-SeatMap -Map $roleJson -Path $roleFile
                            Write-Host "  Scrubbed stale halt for $($s.codename) (chain missing)" -ForegroundColor Yellow
                        }
                    }
                }
                # Optional AGENTS.md / CLAUDE.md: scrub + chain line, missing is non-fatal; always run even when role.json missing or chain missing
                foreach ($pair in @(@($agentsFile, 'AGENTS.md'), @($claudeFile, 'CLAUDE.md'))) {
                    $mdPath = $pair[0]
                    $mdLabel = $pair[1]
                    if (-not (Test-Path -LiteralPath $mdPath)) { continue }
                    $mdContent = Get-Content -LiteralPath $mdPath -Raw
                    $mdScrubbed = Invoke-StaleHaltScrub -Text $mdContent
                    if ($mdScrubbed -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
                        $mdScrubbed = Replace-LiteralRegex -InputText $mdScrubbed -Pattern '(?s)Model chain \(best first\):.+?\(FLOOR\)\.' -Replacement $chainLine
                        $mdScrubbed = Invoke-StaleHaltScrub -Text $mdScrubbed
                    }
                    if (Test-StaleHaltPresent -Text $mdScrubbed) {
                        throw "Seat '$($s.codename)' $mdLabel still contains stale halt text after scrub; refusing sync."
                    }
                    if ($mdScrubbed -ne $mdContent) {
                        Save-Utf8NoBom -Path $mdPath -Content $mdScrubbed
                        Write-Host "  Updated $mdLabel for $($s.codename)" -ForegroundColor Green
                    } elseif ($mdScrubbed -match '(?s)Model chain \(best first\):.+?\(FLOOR\)\.') {
                        Save-Utf8NoBom -Path $mdPath -Content $mdScrubbed
                        Write-Host "  Updated $mdLabel for $($s.codename)" -ForegroundColor Green
                    }
                }
            }
        } catch {
            $syncFatal = [string]$_.Exception.Message
        }
        if ($null -ne $syncFatal) {
            $restoreErrors = [System.Collections.Generic.List[string]]::new()
            foreach ($p in $syncSnapshot.Keys) {
                try { [System.IO.File]::WriteAllBytes($p, $syncSnapshot[$p]) } catch { $restoreErrors.Add("Restore failed for $p : $_") }
            }
            if ($restoreErrors.Count -gt 0) {
                Write-Error ($syncFatal + "`n" + ($restoreErrors -join "`n")) -ErrorAction Continue
            } else {
                Write-Error $syncFatal -ErrorAction Continue
            }
            exit 1
        }
    }
}

if ($SyncNotes -or $All) {
    Write-Host "`n=== Syncing Canvas Notes ===" -ForegroundColor Cyan
    if ($null -eq $preflightNotes) {
        $preflightNotes = Get-TargetSwapNotePaths -WorkspaceIdParam $WorkspaceId -RepoRootParam $repoRoot -SeatMapPathParam $SeatMapPath
    }
    $notesDir = $preflightNotes.NotesDir
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

$verifyFailed = $false
if ($Verify -or $All) {
    $verifyFailed = -not (Invoke-SeatMapWorkspaceVerify -Map $seatMap -WorkspaceIdParam $WorkspaceId -ResolvedWorkspaceIdParam $resolvedWorkspaceId -RepoRootParam $repoRoot)
}

if ($syncMisses.Count -gt 0) {
    $noteFatal = @(
        $syncMisses | Where-Object {
            $_ -match 'Notes directory not found|harness-team-charter|team-restart|Roster table|Launch commands table'
        }
    )
    # Target-swap notes miss: restore map/role/notes/swap-log (B1/A7). Missing
    # other seats' role files stay non-fatal for a committed target swap (A9).
    # Process this before taking a verify exit so swap+syncMiss+drift cannot
    # skip Restore-SwapRollback or the A9 warning path.
    if ($null -ne $swapTarget -and $noteFatal.Count -eq 0) {
        foreach ($m in $syncMisses) { Write-Warning ([string]$m) }
        if (-not $verifyFailed) {
            exit 0
        }
    } else {
        Restore-SwapRollback
        Write-ViolationsAndExit -Violations @($syncMisses)
    }
}

if ($verifyFailed) {
    if ($syncMisses.Count -eq 0) {
        Write-VerifyReceiptIfAll
    }
    exit 1
}

exit 0
