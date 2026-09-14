#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Repeatable on-demand probe that auditions a candidate model on a named host.

.DESCRIPTION
  Wraps the floor-model probe kit (G1 trap, VERDICT/EDIT/PROSE/RETRIEVAL bars,
  G3 cost ladder). With -Seat and -Rung, writes one cell in seat-map.json.
  Without them, prints the result to stdout (scouting mode).

  -WhatIf validates inputs, resolves host to binary, constructs the launch
  command, checks a -Seat/-Rung target when given, enforces the GPT-OSS
  blocklist, and exits without executing. No billable launch.

  OpenCode probes should not run while live OpenCode seats are active: this
  script records ambient reasoning.effort and never edits opencode.jsonc.

.PARAMETER Host
  Canonical platform name. cursor maps to binary agent.

.PARAMETER Model
  Model identifier for the host.

.PARAMETER Test
  Verdict | Containment | Timeout | Edit | Prose | Retrieval | Cost

.PARAMETER Seat
  Seat id or codename. Required with -Rung. Writes that seat-map cell.

.PARAMETER Rung
  head | then | floor. Required with -Seat.

.PARAMETER WhatIf
  Validate, resolve, construct; do not launch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('agy', 'opencode', 'codex', 'cursor', 'junie', 'gemini', 'claude')]
    [Alias('Host')]
    [string]$ProbeHost,

    [Parameter(Mandatory)]
    [string]$Model,

    [Parameter(Mandatory)]
    [ValidateSet('Verdict', 'Containment', 'Timeout', 'Edit', 'Prose', 'Retrieval', 'Cost')]
    [string]$Test,

    [string]$Seat = '',

    [string]$Rung = '',

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot '_json-property.ps1')

$BlockedModels = @('openai/gpt-oss-120b')
$TimeoutSeconds = 600
$JunieProbeEffort = 'high'
$SeatMapPath = Join-Path $PSScriptRoot 'seat-map.json'
$LockPath = Join-Path $PSScriptRoot '.seat-map.lock'

$hostBinaries = @{
    agy      = 'agy'
    opencode = 'opencode'
    codex    = 'codex'
    cursor   = 'agent'
    junie    = 'junie'
    gemini   = 'gemini'
    claude   = 'claude'
}

$taskFiles = @{
    Verdict      = 'v1-trap.txt'
    Containment  = 's3-containment.txt'
    Timeout      = 's1-hello.txt'
    Edit         = 'e1-edit.txt'
    Prose        = 'p1-prose.txt'
    Retrieval    = 'r1-retrieve.txt'
    Cost         = 'v2-false-premise.txt'
}

function Write-ProbeError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-TreeKillCommand {
    param([int]$ProcessId)
    if ($IsWindows) {
        return "taskkill /T /F /PID $ProcessId"
    }
    return "kill -- -$ProcessId"
}

function Stop-ProbeProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    if ($IsWindows) {
        & taskkill /T /F /PID $ProcessId 2>$null | Out-Null
        return
    }
    $pgid = $ProcessId
    $pgidLine = & ps -o pgid= -p $ProcessId 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($pgidLine)) {
        $parsed = 0
        if ([int]::TryParse($pgidLine.Trim(), [ref]$parsed) -and $parsed -gt 0) {
            $pgid = $parsed
        }
    }
    & kill -- "-$pgid" 2>$null | Out-Null
}

function Enter-SeatMapLock {
    if (Test-Path -LiteralPath $LockPath) {
        $raw = (Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue)
        $holder = 0
        if ($raw -and [int]::TryParse($raw.Trim(), [ref]$holder) -and $holder -gt 0) {
            if (Test-ProcessAlive -ProcessId $holder) {
                Write-ProbeError "Seat-map lock held by PID $holder ($LockPath)."
            }
        }
    }
    [System.IO.File]::WriteAllText($LockPath, [string]$PID, [System.Text.UTF8Encoding]::new($false))
}

function Exit-SeatMapLock {
    if (-not (Test-Path -LiteralPath $LockPath)) { return }
    $raw = (Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue)
    if ($raw -and $raw.Trim() -eq [string]$PID) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-ProbePool {
    param([string]$HostName, [string]$ModelName)
    switch ($HostName) {
        'agy' {
            if ($ModelName -match '^(claude|gpt-oss|gpt-)') { return 'AGY-C' }
            return 'AGY-G'
        }
        'opencode' {
            if ($ModelName -like 'openrouter/*') { return 'OPENROUTER' }
            return 'ZEN'
        }
        'codex' { return 'CODEX' }
        'cursor' { return 'CURSOR' }
        'junie' { return 'JETBRAINS' }
        'gemini' { return 'GEMINI' }
        'claude' { return 'CLAUDE' }
    }
}

function Resolve-ProbeKitRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:PROBE_KIT_ROOT) { [void]$candidates.Add($env:PROBE_KIT_ROOT) }
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    [void]$candidates.Add((Join-Path $repoRoot (Join-Path 'artifacts' 'probe-kit')))
    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Temp/claude/F--Dev-dotnet-agent-harness--claude-worktrees-maestri-process-improvements-e26d8b/0d77be9b-0c42-4460-915e-ce0715ca282e/scratchpad/probe-kit'))
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $readme = Join-Path $candidate 'README.md'
        if (Test-Path -LiteralPath $readme) { return $candidate }
    }
    return $null
}

function Get-ProbeTaskPath {
    param([string]$TestName, [string]$KitRoot)
    $fileName = $taskFiles[$TestName]
    if ($KitRoot) {
        $path = Join-Path (Join-Path $KitRoot 'tasks') $fileName
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Get-ProbeWorkingDirectory {
    param([string]$TestName, [string]$RepoRoot)
    switch ($TestName) {
        'Verdict' { return (Join-Path ([System.IO.Path]::GetTempPath()) 'probe-verdict-empty') }
        'Containment' { return (Join-Path $HOME 'probe-sandbox') }
        'Edit' { return (Join-Path $HOME 'edit-run') }
        'Timeout' { return $RepoRoot }
        default { return $RepoRoot }
    }
}

function New-LaunchSpec {
    param(
        [string]$HostName,
        [string]$Binary,
        [string]$ModelName,
        [string]$TestName,
        [string]$WorkDir,
        [string]$TaskPath
    )

    $taskRef = if ($TaskPath) { $TaskPath } else { "tasks/$($taskFiles[$TestName])" }
    $arguments = @()
    $stdinMode = $false
    $jsonStdin = $false

    switch ($HostName) {
        'agy' {
            $arguments = @(
                '--input-format', 'text',
                '--output-format', 'json',
                '--model', $ModelName,
                '--print-timeout', '10m',
                '--disable-slash-commands',
                '--add-dir', $WorkDir
            )
            if ($TestName -eq 'Edit') { $arguments += @('--mode', 'accept-edits') }
            $stdinMode = $true
        }
        'opencode' {
            $arguments = @('run', '--format', 'json', '-m', $ModelName)
            if ($TaskPath) { $arguments += $TaskPath } else { $arguments += $taskRef }
        }
        'codex' {
            $arguments = @('exec', '--model', $ModelName, '--effort', 'xhigh')
            $stdinMode = $true
        }
        'cursor' {
            $arguments = @('-p', '--force', '--model', $ModelName, '--output-format', 'json')
            $stdinMode = $true
        }
        'junie' {
            $arguments = @(
                '--skip-update-check',
                '--input-format=json',
                '--model', $ModelName,
                '--effort', $JunieProbeEffort,
                '--project', $WorkDir
            )
            $stdinMode = $true
            $jsonStdin = $true
        }
        'gemini' {
            $arguments = @('--skip-trust', '-y', '-m', $ModelName, '-o', 'json')
            if ($TaskPath) { $arguments += @('-p', $TaskPath) } else { $arguments += @('-p', $taskRef) }
        }
        'claude' {
            $arguments = @(
                '-p',
                '--model', $ModelName,
                '--permission-mode', 'dontAsk',
                '--output-format', 'json'
            )
            $stdinMode = $true
        }
    }

    $commandLine = @($Binary) + $arguments
    return [pscustomobject]@{
        Binary     = $Binary
        Arguments  = $arguments
        Command    = ($commandLine | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
        Stdin      = $stdinMode
        JsonStdin  = $jsonStdin
        TaskPath   = $taskRef
        WorkDir    = $WorkDir
    }
}

function Get-OpenCodeAmbientEffort {
    $configPath = Join-Path (Join-Path (Join-Path $HOME '.config') 'opencode') 'opencode.jsonc'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $configPath = Join-Path (Join-Path (Join-Path $HOME '.config') 'opencode') 'opencode.json'
    }
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    $raw = Get-Content -LiteralPath $configPath -Raw
    $stripped = [regex]::Replace($raw, '(?m)//.*?$', '')
    $stripped = [regex]::Replace($stripped, '/\*[\s\S]*?\*/', '')
    try {
        $json = $stripped | ConvertFrom-Json
    }
    catch {
        return $null
    }
    $effort = Get-JsonPath -Object $json -Path @('reasoning', 'effort')
    if ($null -eq $effort) {
        $effort = Get-JsonPath -Object $json -Path @('agent', 'reasoning', 'effort')
    }
    if ($null -eq $effort) { return $null }
    return [string]$effort
}

function Read-JunieEffortOnly {
    param([string]$SettingsPath, [string]$ModelName)
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return [pscustomobject]@{ Exists = $false; HadKey = $false; Value = $null; Raw = $null }
    }
    $raw = Get-Content -LiteralPath $SettingsPath -Raw
    $settings = $raw | ConvertFrom-Json
    $map = Get-JsonPath -Object $settings -Path @('effortPerModel')
    $hadKey = $false
    $value = $null
    if ($null -ne $map -and $null -ne $map.PSObject.Properties[$ModelName]) {
        $hadKey = $true
        $value = $map.$ModelName
    }
    return [pscustomobject]@{ Exists = $true; HadKey = $hadKey; Value = $value; Raw = $raw }
}

function Write-JunieEffortOnly {
    param([string]$SettingsPath, [string]$ModelName, [string]$Effort)
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return }
    $settings = (Get-Content -LiteralPath $SettingsPath -Raw) | ConvertFrom-Json
    if (-not (Test-JsonProperty -Object $settings -Name 'effortPerModel') -or $null -eq $settings.effortPerModel) {
        $settings | Add-Member -NotePropertyName 'effortPerModel' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($null -ne $settings.effortPerModel.PSObject.Properties[$ModelName]) {
        $settings.effortPerModel.$ModelName = $Effort
    }
    else {
        $settings.effortPerModel | Add-Member -NotePropertyName $ModelName -NotePropertyValue $Effort
    }
    $json = $settings | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($SettingsPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Restore-JunieEffort {
    param($Backup, [string]$SettingsPath, [string]$ModelName)
    if ($null -eq $Backup -or -not $Backup.Exists) { return }
    if ($null -ne $Backup.Raw) {
        [System.IO.File]::WriteAllText($SettingsPath, $Backup.Raw, [System.Text.UTF8Encoding]::new($false))
        return
    }
}

function Set-NoteValue {
    param($Object, [string]$Name, $Value)
    if (Test-JsonProperty -Object $Object -Name $Name) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Resolve-SeatCell {
    param([string]$SeatName, [string]$RungName, [string]$MapPath)
    if (-not (Test-Path -LiteralPath $MapPath)) {
        Write-ProbeError "Seat map not found: $MapPath"
    }
    $map = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json
    $seatObj = $null
    foreach ($candidate in @($map.seats)) {
        $id = if (Test-JsonProperty $candidate 'id') { [string]$candidate.id } else { '' }
        $code = if (Test-JsonProperty $candidate 'codename') { [string]$candidate.codename } else { '' }
        $name = if (Test-JsonProperty $candidate 'name') { [string]$candidate.name } else { '' }
        if ($id -eq $SeatName -or $code -eq $SeatName -or $name -eq $SeatName) {
            $seatObj = $candidate
            break
        }
    }
    if ($null -eq $seatObj) {
        Write-ProbeError "Seat '$SeatName' not found in seat-map.json."
    }
    $rungs = Get-JsonPath -Object $seatObj -Path @('rungs')
    $cell = Get-JsonPath -Object $rungs -Path @($RungName)
    if ($null -eq $cell) {
        Write-ProbeError "Seat '$SeatName' has no '$RungName' rung."
    }
    return [pscustomobject]@{ Map = $map; Seat = $seatObj; Cell = $cell }
}

function New-CostRecord {
    param(
        [ValidateSet('actual', 'estimated', 'unknown')]
        [string]$Source,
        $Usd = $null
    )
    $record = [ordered]@{ source = $Source }
    if ($null -ne $Usd) { $record.usd = $Usd }
    return [pscustomobject]$record
}

function Write-SeatCell {
    param(
        $Resolved,
        [string]$MapPath,
        [string]$HostName,
        [string]$ModelName,
        [string]$Pool,
        [string]$Launch,
        [string]$Evidence,
        $Cost,
        $Metadata
    )
    $cell = $Resolved.Cell
    Set-NoteValue $cell 'host' $HostName
    Set-NoteValue $cell 'model' $ModelName
    Set-NoteValue $cell 'pool' $Pool
    Set-NoteValue $cell 'launch' $Launch
    Set-NoteValue $cell 'evidence' $Evidence
    Set-NoteValue $cell 'evidenceDate' ((Get-Date).ToString('yyyy-MM-dd'))
    Set-NoteValue $cell 'cost' $Cost
    if ($null -ne $Metadata) {
        Set-NoteValue $cell 'metadata' $Metadata
    }
    Set-NoteValue $Resolved.Map 'updatedAt' ((Get-Date).ToString('yyyy-MM-dd'))
    $json = $Resolved.Map | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($MapPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-ProbeLaunch {
    param($Launch, [int]$WaitSeconds)

    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("model-probe-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ("model-probe-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    New-Item -ItemType File -Path $outFile -Force | Out-Null
    New-Item -ItemType File -Path $errFile -Force | Out-Null

    $fileName = $Launch.Binary
    $argList = @($Launch.Arguments)
    if (-not $IsWindows) {
        $fileName = 'setsid'
        $argList = @('--', $Launch.Binary) + $Launch.Arguments
    }

    $start = @{
        FilePath               = $fileName
        ArgumentList           = $argList
        WorkingDirectory       = $Launch.WorkDir
        PassThru               = $true
        NoNewWindow            = $true
        RedirectStandardOutput = $outFile
        RedirectStandardError  = $errFile
    }
    $proc = Start-Process @start
    $cutoff = $false
    $waitMs = [Math]::Max(1, $WaitSeconds) * 1000
    if (-not $proc.WaitForExit($waitMs)) {
        $cutoff = $true
        Stop-ProbeProcessTree -ProcessId $proc.Id
        $null = $proc.WaitForExit(5000)
    }
    $code = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
    $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        ExitCode = $code
        Cutoff   = $cutoff
        StdOut   = $stdout
        StdErr   = $stderr
        Pid      = $proc.Id
    }
}

# --- validate ---
$hasSeat = -not [string]::IsNullOrWhiteSpace($Seat)
$hasRung = -not [string]::IsNullOrWhiteSpace($Rung)
if ($hasSeat -ne $hasRung) {
    Write-ProbeError '-Seat and -Rung must be passed together.'
}
if ($hasRung -and $Rung -notin @('head', 'then', 'floor')) {
    Write-ProbeError "-Rung must be head, then, or floor (got '$Rung')."
}

foreach ($blocked in $BlockedModels) {
    if ($Model -eq $blocked) {
        Write-ProbeError "Blocked model '$Model' is refused (GPT-OSS blocklist)."
    }
}

$binary = $hostBinaries[$ProbeHost]
if ([string]::IsNullOrWhiteSpace($binary)) {
    Write-ProbeError "No binary mapping for host '$ProbeHost'."
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$kitRoot = Resolve-ProbeKitRoot
$taskPath = Get-ProbeTaskPath -TestName $Test -KitRoot $kitRoot
$workDir = Get-ProbeWorkingDirectory -TestName $Test -RepoRoot $repoRoot
$pool = Resolve-ProbePool -HostName $ProbeHost -ModelName $Model
$launch = New-LaunchSpec -HostName $ProbeHost -Binary $binary -ModelName $Model -TestName $Test -WorkDir $workDir -TaskPath $taskPath
$ambientEffort = $null
if ($ProbeHost -eq 'opencode') {
    $ambientEffort = Get-OpenCodeAmbientEffort
}

$resolvedSeat = $null
if ($hasSeat) {
    $resolvedSeat = Resolve-SeatCell -SeatName $Seat -RungName $Rung -MapPath $SeatMapPath
}

Write-Host "Host:     $ProbeHost"
Write-Host "Binary:   $binary"
Write-Host "Model:    $Model"
Write-Host "Test:     $Test"
Write-Host "Pool:     $pool"
Write-Host "Launch:   $($launch.Command)"
Write-Host "WorkDir:  $workDir"
if ($taskPath) { Write-Host "Task:     $taskPath" }
if ($ProbeHost -eq 'opencode') {
    Write-Host 'Note:     OpenCode probes should not run while live OpenCode seats are active.'
    if ($null -ne $ambientEffort) {
        Write-Host "Ambient:  reasoning.effort=$ambientEffort"
    }
    else {
        Write-Host 'Ambient:  reasoning.effort=(unrecorded)'
    }
}
if ($Test -eq 'Timeout') {
    Write-Host 'TreeKillWindows: taskkill /T /F /PID <pid>'
    Write-Host 'TreeKillLinux: kill -- -$pgid'
    Write-Host ("TreeKill: " + (Get-TreeKillCommand -ProcessId ([int]0)))
}

if ($WhatIf) {
    Write-Host 'WhatIf:   validate+resolve+construct complete; launch will not execute.'
    exit 0
}

$junieSettings = Join-Path (Join-Path $HOME '.junie') 'settings.json'
$junieBackup = $null
$locked = $false
try {
    Enter-SeatMapLock
    $locked = $true

    if ($ProbeHost -eq 'junie') {
        $junieBackup = Read-JunieEffortOnly -SettingsPath $junieSettings -ModelName $Model
        Write-JunieEffortOnly -SettingsPath $junieSettings -ModelName $Model -Effort $JunieProbeEffort
    }

    if ($Test -in @('Verdict', 'Containment') -and -not (Test-Path -LiteralPath $workDir)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    $run = Invoke-ProbeLaunch -Launch $launch -WaitSeconds $TimeoutSeconds
    $cost = New-CostRecord -Source 'unknown'
    $evidence = if ($run.Cutoff) { 'unmeasured' } else { 'probed' }
    $metadata = [pscustomobject]@{
        test   = $Test
        cutoff = $run.Cutoff
        exit   = $run.ExitCode
    }
    if ($null -ne $ambientEffort) {
        Set-NoteValue $metadata 'opencodeAmbientEffort' $ambientEffort
    }

    $result = [pscustomobject]@{
        host         = $ProbeHost
        binary       = $binary
        model        = $Model
        test         = $Test
        pool         = $pool
        launch       = $launch.Command
        evidence     = $evidence
        evidenceDate = (Get-Date).ToString('yyyy-MM-dd')
        cost         = $cost
        cutoff       = $run.Cutoff
        exitCode     = $run.ExitCode
        metadata     = $metadata
    }

    if ($hasSeat) {
        Write-SeatCell -Resolved $resolvedSeat -MapPath $SeatMapPath -HostName $ProbeHost -ModelName $Model -Pool $pool -Launch $launch.Command -Evidence $evidence -Cost $cost -Metadata $metadata
        Write-Host "Wrote cell $Seat/$Rung evidence=$evidence cost.source=$($cost.source)"
    }
    else {
        $result | ConvertTo-Json -Depth 8
    }

    if ($run.Cutoff) { exit 1 }
    exit 0
}
finally {
    if ($ProbeHost -eq 'junie') {
        Restore-JunieEffort -Backup $junieBackup -SettingsPath $junieSettings -ModelName $Model
    }
    if ($locked) { Exit-SeatMapLock }
}
