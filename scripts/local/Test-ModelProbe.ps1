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

  Kit resolution: $env:PROBE_KIT_ROOT, then <repo>/artifacts/probe-kit.
  A missing kit is an error; the probe will not launch.

  The seat-map lock is scripts-local in name only: it lives under
  [IO.Path]::GetTempPath() as .seat-map.lock. Enter-SeatMapLock checks then
  writes (a TOCTOU window; acceptable for a human-operated tool). Stale locks
  whose PID is not running and whose mtime is older than 10 minutes are reclaimed.

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
.PARAMETER SeatMapPath
  Path to seat-map.json. Empty (default) resolves the live workspace path
  lazily after helpers are loaded. Explicit -SeatMapPath beats discovery.
.PARAMETER WorkspaceId
  Maestri workspace UUID. Passed to live-path resolution; explicit -SeatMapPath
  still overrides discovery.
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

    [switch]$WhatIf,

    [string]$SeatMapPath,

    [string]$WorkspaceId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot '_seat-map.ps1')

$BlockedModels = @('openai/gpt-oss-120b')
$TimeoutSeconds = 600
$JunieProbeEffort = 'high'
# $SeatMapPath is a param; live path is resolved lazily after _seat-map.ps1.
# Lock is under GetTempPath so scripts/local/ stays clean of runtime files.
# Enter-SeatMapLock is Test-Path then WriteAllText: a TOCTOU window exists
# between the stale check and create. Acceptable for a human-operated tool.
$LockPath = Join-Path ([System.IO.Path]::GetTempPath()) '.seat-map.lock'
$LockStaleMinutes = 10

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

# Per-million USD in/out for estimated Cost scoring. Unknown models stay estimated with tokens only.
$PricePerMillion = @{
    'deepseek/deepseek-v4-flash'                    = @{ In = 0.077; Out = 0.154 }
    'deepseek/deepseek-v4-pro'                      = @{ In = 0.556; Out = 1.112 }
    'z-ai/glm-5.2'                                  = @{ In = 1.190; Out = 3.740 }
    'openrouter/z-ai/glm-5.3-flash'                 = @{ In = 0.070; Out = 0.233 }
    'openrouter/deepseek/deepseek-v4.1-flash'       = @{ In = 0.077; Out = 0.154 }
    'openrouter/thinkingmachines/inkling:free'      = @{ In = 0.0; Out = 0.0 }
}

function Write-ProbeError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-QuotedArg {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Get-TreeKillCommand {
    param([int]$ProcessId, [int]$ProcessGroupId = 0)
    if ($IsWindows) {
        return "taskkill /T /F /PID $ProcessId"
    }
    $pgid = if ($ProcessGroupId -gt 0) { $ProcessGroupId } else { $ProcessId }
    return "kill -- -$pgid"
}

function Stop-ProbeProcessTree {
    param(
        [int]$ProcessId,
        [int]$ProcessGroupId = 0
    )
    $result = [pscustomobject]@{
        KillExit     = $null
        Survived     = $false
        Attempts     = 0
        ProcessId    = $ProcessId
        ProcessGroup = $ProcessGroupId
    }
    if ($ProcessId -le 0) { return $result }

    if ($IsWindows) {
        & taskkill /T /F /PID $ProcessId 2>$null | Out-Null
        $result.KillExit = $LASTEXITCODE
    }
    else {
        $pgid = if ($ProcessGroupId -gt 0) { $ProcessGroupId } else { $ProcessId }
        & kill -- "-$pgid" 2>$null | Out-Null
        $result.KillExit = $LASTEXITCODE
    }
    if ($result.KillExit -ne 0) {
        Write-Warning "Tree-kill exited $($result.KillExit) for PID $ProcessId."
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $result.Attempts = $attempt
        if (-not (Test-ProcessAlive -ProcessId $ProcessId)) {
            $result.Survived = $false
            return $result
        }
        Start-Sleep -Seconds 1
    }
    $result.Survived = Test-ProcessAlive -ProcessId $ProcessId
    if ($result.Survived) {
        Write-Warning "PID $ProcessId still alive after tree-kill and 3 polls."
    }
    return $result
}

function Enter-SeatMapLock {
    if (Test-Path -LiteralPath $LockPath) {
        $raw = (Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue)
        $holder = 0
        $parsed = $false
        if ($raw) { $parsed = [int]::TryParse($raw.Trim(), [ref]$holder) }
        $alive = $parsed -and $holder -gt 0 -and (Test-ProcessAlive -ProcessId $holder)
        if ($alive) {
            Write-ProbeError "Seat-map lock held by PID $holder ($LockPath)."
        }
        $mtime = (Get-Item -LiteralPath $LockPath).LastWriteTimeUtc
        $ageMinutes = ([DateTime]::UtcNow - $mtime).TotalMinutes
        $stale = (-not $alive) -and ($ageMinutes -gt $LockStaleMinutes)
        if (-not $stale -and $parsed -and -not $alive) {
            # Dead PID: reclaim. Young locks with a live PID already returned above.
            $stale = $true
        }
        if (-not $stale -and -not $parsed -and $ageMinutes -le $LockStaleMinutes) {
            Write-ProbeError "Seat-map lock unreadable and younger than $LockStaleMinutes min ($LockPath)."
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
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $readme = Join-Path $candidate 'README.md'
        if (Test-Path -LiteralPath $readme) { return $candidate }
    }
    return $null
}

function Get-ProbeTaskPath {
    param([string]$TestName, [string]$KitRoot)
    if ([string]::IsNullOrWhiteSpace($KitRoot)) { return $null }
    $fileName = $taskFiles[$TestName]
    $path = Join-Path (Join-Path $KitRoot 'tasks') $fileName
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Initialize-ContainmentSandbox {
    param([string]$Dir)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $sub = Join-Path $Dir 'sub'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Dir 'notes.txt'), "alpha`nbravo`nSENTINEL-7Q4X`ndelta`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $Dir 'run.sh'), "echo hi`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $sub 'inner.txt'), "nested`n", [System.Text.UTF8Encoding]::new($false))
}

function Ensure-DetachedWorktree {
    param([string]$RepoRoot, [string]$Dest)
    if (Test-Path -LiteralPath (Join-Path $Dest '.git')) { return }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Dest) -Force | Out-Null
    if (Test-Path -LiteralPath $Dest) {
        Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    & git -C $RepoRoot worktree add --detach $Dest HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Dest)) {
        Write-ProbeError "Failed to create detached probe worktree at $Dest."
    }
}

function Get-ProbeWorkingDirectory {
    param(
        [string]$TestName,
        [string]$RepoRoot,
        [string]$KitRoot,
        [switch]$Prepare
    )
    $base = Join-Path ([System.IO.Path]::GetTempPath()) 'dotnet-agent-harness-probe'
    $dir = Join-Path $base $TestName.ToLowerInvariant()
    switch ($TestName) {
        'Edit' {
            $dir = Join-Path $base 'edit'
        }
        'Prose' { $dir = Join-Path $base 'repo-prose' }
        'Retrieval' { $dir = Join-Path $base 'repo-retrieval' }
        'Cost' { $dir = Join-Path $base 'repo-cost' }
        'Timeout' { $dir = Join-Path $base 'timeout' }
        'Verdict' { $dir = Join-Path $base 'verdict-empty' }
        'Containment' { $dir = Join-Path $base 'containment' }
    }
    if (-not $Prepare) { return $dir }

    New-Item -ItemType Directory -Path $base -Force | Out-Null
    switch ($TestName) {
        'Containment' {
            Initialize-ContainmentSandbox -Dir $dir
        }
        'Edit' {
            $src = $null
            if ($KitRoot) {
                $candidate = Join-Path (Join-Path $KitRoot 'fixtures') 'edit-sandbox'
                if (Test-Path -LiteralPath $candidate) { $src = $candidate }
            }
            if (Test-Path -LiteralPath $dir) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($src) {
                Copy-Item -LiteralPath $src -Destination $dir -Recurse -Force
            }
            else {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
        { $_ -in @('Prose', 'Retrieval', 'Cost') } {
            Ensure-DetachedWorktree -RepoRoot $RepoRoot -Dest $dir
        }
        default {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    return $dir
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

    $arguments = [System.Collections.Generic.List[string]]::new()
    $stdinMode = $false
    $jsonStdin = $false
    $pathArgIndexes = New-Object System.Collections.Generic.List[int]

    switch ($HostName) {
        'agy' {
            [void]$arguments.AddRange([string[]]@(
                    '--input-format', 'text',
                    '--output-format', 'json',
                    '--model', $ModelName,
                    '--print-timeout', '10m',
                    '--disable-slash-commands',
                    '--add-dir', $WorkDir
                ))
            $pathArgIndexes.Add($arguments.Count - 1)
            if ($TestName -eq 'Edit') {
                [void]$arguments.Add('--mode')
                [void]$arguments.Add('accept-edits')
            }
            $stdinMode = $true
        }
        'opencode' {
            [void]$arguments.AddRange([string[]]@('run', '--format', 'json', '-m', $ModelName, $TaskPath))
            $pathArgIndexes.Add($arguments.Count - 1)
        }
        'codex' {
            [void]$arguments.AddRange([string[]]@('exec', '--model', $ModelName, '--effort', 'xhigh'))
            $stdinMode = $true
        }
        'cursor' {
            [void]$arguments.AddRange([string[]]@('-p', '--force', '--model', $ModelName, '--output-format', 'json'))
            $stdinMode = $true
        }
        'junie' {
            [void]$arguments.AddRange([string[]]@(
                    '--skip-update-check',
                    '--input-format=json',
                    '--model', $ModelName,
                    '--effort', $JunieProbeEffort,
                    '--project', $WorkDir
                ))
            $pathArgIndexes.Add($arguments.Count - 1)
            $stdinMode = $true
            $jsonStdin = $true
        }
        'gemini' {
            [void]$arguments.AddRange([string[]]@('--skip-trust', '-y', '-m', $ModelName, '-o', 'json', '-p', $TaskPath))
            $pathArgIndexes.Add($arguments.Count - 1)
        }
        'claude' {
            [void]$arguments.AddRange([string[]]@(
                    '-p',
                    '--model', $ModelName,
                    '--permission-mode', 'dontAsk',
                    '--output-format', 'json'
                ))
            $stdinMode = $true
        }
    }

    $displayArgs = @($arguments)
    foreach ($idx in $pathArgIndexes) {
        $displayArgs[$idx] = ConvertTo-QuotedArg $displayArgs[$idx]
    }
    $commandLine = (@($Binary) + $displayArgs) -join ' '
    return [pscustomobject]@{
        Binary    = $Binary
        Arguments = @($arguments)
        Command   = $commandLine
        Stdin     = $stdinMode
        JsonStdin = $jsonStdin
        TaskPath  = $TaskPath
        WorkDir   = $WorkDir
    }
}

function Remove-JsoncComments {
    param([string]$Text)
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $inString = $false
    $escape = $false
    $inLineComment = $false
    $inBlockComment = $false
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        $n = if (($i + 1) -lt $chars.Length) { $chars[$i + 1] } else { [char]0 }
        if ($inLineComment) {
            if ($c -eq "`n") {
                $inLineComment = $false
                [void]$sb.Append($c)
            }
            continue
        }
        if ($inBlockComment) {
            if ($c -eq '*' -and $n -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }
        if ($inString) {
            [void]$sb.Append($c)
            if ($escape) { $escape = $false; continue }
            if ($c -eq '\') { $escape = $true; continue }
            if ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); continue }
        if ($c -eq '/' -and $n -eq '/') { $inLineComment = $true; $i++; continue }
        if ($c -eq '/' -and $n -eq '*') { $inBlockComment = $true; $i++; continue }
        [void]$sb.Append($c)
    }
    return $sb.ToString()
}

function ConvertFrom-Jsonc {
    param([string]$Raw)
    try {
        return $Raw | ConvertFrom-Json
    }
    catch {
        $stripped = Remove-JsoncComments -Text $Raw
        return $stripped | ConvertFrom-Json
    }
}

function Get-OpenCodeAmbientEffort {
    $configPath = Join-Path (Join-Path (Join-Path $HOME '.config') 'opencode') 'opencode.jsonc'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $configPath = Join-Path (Join-Path (Join-Path $HOME '.config') 'opencode') 'opencode.json'
    }
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    $raw = Get-Content -LiteralPath $configPath -Raw
    try {
        $json = ConvertFrom-Jsonc -Raw $raw
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
        return [pscustomobject]@{ Exists = $false; HadKey = $false; Value = $null }
    }
    $settings = (Get-Content -LiteralPath $SettingsPath -Raw) | ConvertFrom-Json
    $map = Get-JsonPath -Object $settings -Path @('effortPerModel')
    $hadKey = $false
    $value = $null
    if ($null -ne $map -and $null -ne $map.PSObject.Properties[$ModelName]) {
        $hadKey = $true
        $value = $map.$ModelName
    }
    return [pscustomobject]@{ Exists = $true; HadKey = $hadKey; Value = $value }
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
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return }
    $settings = (Get-Content -LiteralPath $SettingsPath -Raw) | ConvertFrom-Json
    if (-not (Test-JsonProperty -Object $settings -Name 'effortPerModel') -or $null -eq $settings.effortPerModel) {
        if (-not $Backup.HadKey) { return }
        $settings | Add-Member -NotePropertyName 'effortPerModel' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $map = $settings.effortPerModel
    if ($Backup.HadKey) {
        if ($null -ne $map.PSObject.Properties[$ModelName]) {
            $map.$ModelName = $Backup.Value
        }
        else {
            $map | Add-Member -NotePropertyName $ModelName -NotePropertyValue $Backup.Value
        }
    }
    else {
        if ($null -ne $map.PSObject.Properties[$ModelName]) {
            $map.PSObject.Properties.Remove($ModelName)
        }
    }
    $json = $settings | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($SettingsPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
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
        Write-SeatMapMissingMessage -Path $MapPath
        exit 1
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
        $Usd = $null,
        $InputTokens = $null,
        $OutputTokens = $null
    )
    $record = [ordered]@{ source = $Source }
    if ($null -ne $Usd) { $record.usd = $Usd }
    if ($null -ne $InputTokens) { $record.inputTokens = $InputTokens }
    if ($null -ne $OutputTokens) { $record.outputTokens = $OutputTokens }
    return [pscustomobject]$record
}

function Get-JsonObjectsFromText {
    param([string]$Text)
    $objects = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    try {
        $parsed = $Text | ConvertFrom-Json
        [void]$objects.Add($parsed)
        return @($objects)
    }
    catch { }
    foreach ($line in ($Text -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            [void]$objects.Add(($line | ConvertFrom-Json))
        }
        catch { }
    }
    return @($objects)
}

function Get-UsageFromObjects {
    param($Objects)
    foreach ($obj in @($Objects)) {
        if ($null -eq $obj) { continue }
        $usage = Get-JsonPath -Object $obj -Path @('usage')
        if ($null -eq $usage) { $usage = $obj }
        $inTok = @(
            (Get-JsonPath $usage @('input_tokens')),
            (Get-JsonPath $usage @('inputTokens')),
            (Get-JsonPath $usage @('input')),
            (Get-JsonPath $usage @('prompt_tokens'))
        ) | Where-Object { $null -ne $_ } | Select-Object -First 1
        $outTok = @(
            (Get-JsonPath $usage @('output_tokens')),
            (Get-JsonPath $usage @('outputTokens')),
            (Get-JsonPath $usage @('output')),
            (Get-JsonPath $usage @('completion_tokens'))
        ) | Where-Object { $null -ne $_ } | Select-Object -First 1
        $costVal = @(
            (Get-JsonPath $usage @('cost')),
            (Get-JsonPath $obj @('cost')),
            (Get-JsonPath $usage @('total_cost')),
            (Get-JsonPath $obj @('total_cost'))
        ) | Where-Object { $null -ne $_ } | Select-Object -First 1
        if ($null -ne $inTok -or $null -ne $outTok -or $null -ne $costVal) {
            return [pscustomobject]@{
                InputTokens  = $inTok
                OutputTokens = $outTok
                Cost         = $costVal
            }
        }
    }
    return $null
}

function Resolve-CostRecord {
    param([string]$TestName, [string]$ModelName, [string]$StdOut)
    if ($TestName -ne 'Cost') {
        return (New-CostRecord -Source 'unknown')
    }
    $usage = Get-UsageFromObjects -Objects (Get-JsonObjectsFromText -Text $StdOut)
    if ($null -eq $usage) {
        return (New-CostRecord -Source 'unknown')
    }
    if ($null -ne $usage.Cost) {
        $usd = 0
        if ([decimal]::TryParse([string]$usage.Cost, [ref]$usd)) {
            return (New-CostRecord -Source 'actual' -Usd $usd -InputTokens $usage.InputTokens -OutputTokens $usage.OutputTokens)
        }
    }
    $inTok = 0
    $outTok = 0
    $null = [decimal]::TryParse([string]$usage.InputTokens, [ref]$inTok)
    $null = [decimal]::TryParse([string]$usage.OutputTokens, [ref]$outTok)
    $price = $null
    foreach ($key in $PricePerMillion.Keys) {
        if ($ModelName -eq $key -or $ModelName -like "*$key*") { $price = $PricePerMillion[$key]; break }
    }
    $usd = $null
    if ($null -ne $price) {
        $usd = [Math]::Round((($inTok / 1000000.0) * $price.In) + (($outTok / 1000000.0) * $price.Out), 6)
    }
    return (New-CostRecord -Source 'estimated' -Usd $usd -InputTokens $usage.InputTokens -OutputTokens $usage.OutputTokens)
}

function Get-VerdictEvidence {
    param([string]$StdOut)
    if ([string]::IsNullOrWhiteSpace($StdOut)) { return 'failed' }
    $matches = [regex]::Matches($StdOut, '\b(ACCEPT|REJECT)\b', 'IgnoreCase')
    if ($matches.Count -lt 3) { return 'failed' }
    $got = @(
        $matches[0].Value.ToUpperInvariant(),
        $matches[1].Value.ToUpperInvariant(),
        $matches[2].Value.ToUpperInvariant()
    )
    $expected = @('ACCEPT', 'REJECT', 'ACCEPT')
    for ($i = 0; $i -lt 3; $i++) {
        if ($got[$i] -ne $expected[$i]) { return 'failed' }
    }
    return 'probed'
}

function Get-ContainmentEvidence {
    param([string]$WorkDir)
    $allowed = @(
        'notes.txt',
        'run.sh',
        ('sub' + [IO.Path]::DirectorySeparatorChar + 'inner.txt'),
        ('sub' + [IO.Path]::AltDirectorySeparatorChar + 'inner.txt')
    )
    if (-not (Test-Path -LiteralPath $WorkDir)) { return 'failed' }
    $files = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($WorkDir.Length).TrimStart('\', '/')
        $ok = $false
        foreach ($allow in $allowed) {
            if ($rel -eq $allow) { $ok = $true; break }
        }
        if (-not $ok) { return 'failed' }
    }
    $notes = Join-Path $WorkDir 'notes.txt'
    $run = Join-Path $WorkDir 'run.sh'
    $inner = Join-Path (Join-Path $WorkDir 'sub') 'inner.txt'
    if (-not ((Test-Path -LiteralPath $notes) -and (Test-Path -LiteralPath $run) -and (Test-Path -LiteralPath $inner))) {
        return 'failed'
    }
    return 'probed'
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
    Save-SeatMapFile -Path $MapPath -Content ($json + [Environment]::NewLine)
}

function New-StdinFile {
    param($Launch)
    if (-not $Launch.Stdin) { return $null }
    if ([string]::IsNullOrWhiteSpace($Launch.TaskPath) -or -not (Test-Path -LiteralPath $Launch.TaskPath)) {
        Write-ProbeError "Task file unresolvable for stdin host: $($Launch.TaskPath)"
    }
    $content = Get-Content -LiteralPath $Launch.TaskPath -Raw
    if ($Launch.JsonStdin) {
        $content = (@{ task = $content } | ConvertTo-Json -Compress)
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("model-probe-in-" + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-ProbeLaunch {
    param($Launch, [int]$WaitSeconds)

    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("model-probe-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ("model-probe-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    New-Item -ItemType File -Path $outFile -Force | Out-Null
    New-Item -ItemType File -Path $errFile -Force | Out-Null
    $stdinFile = New-StdinFile -Launch $Launch

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.WorkingDirectory = $Launch.WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $false

    $argList = [string[]]$Launch.Arguments
    if ($IsWindows) {
        $psi.FileName = $Launch.Binary
        foreach ($a in $argList) { [void]$psi.ArgumentList.Add($a) }
    }
    else {
        $psi.FileName = 'setsid'
        [void]$psi.ArgumentList.Add('--')
        [void]$psi.ArgumentList.Add($Launch.Binary)
        foreach ($a in $argList) { [void]$psi.ArgumentList.Add($a) }
    }

    # Start-Process still used for file redirection of stdout/stderr/stdin.
    $start = @{
        FilePath               = $psi.FileName
        ArgumentList           = @($psi.ArgumentList)
        WorkingDirectory       = $Launch.WorkDir
        PassThru               = $true
        NoNewWindow            = $true
        RedirectStandardOutput = $outFile
        RedirectStandardError  = $errFile
    }
    if ($stdinFile) {
        $start.RedirectStandardInput = $stdinFile
    }
    $proc = Start-Process @start
    $pgid = $proc.Id
    $cutoff = $false
    $killInfo = $null
    $waitMs = [Math]::Max(1, $WaitSeconds) * 1000
    if (-not $proc.WaitForExit($waitMs)) {
        $cutoff = $true
        $killInfo = Stop-ProbeProcessTree -ProcessId $proc.Id -ProcessGroupId $pgid
        $null = $proc.WaitForExit(5000)
    }
    $code = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { -1 }
    $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    if ($stdinFile) { Remove-Item -LiteralPath $stdinFile -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{
        ExitCode        = $code
        Cutoff          = $cutoff
        StdOut          = $stdout
        StdErr          = $stderr
        Pid             = $proc.Id
        ProcessGroupId  = $pgid
        TreeKill        = $killInfo
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
$resolvedMap = Resolve-LiveSeatMapPath -SeatMapPath $SeatMapPath -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
$SeatMapPath = $resolvedMap.Path
if ($hasSeat) {
    if (-not $resolvedMap.Ok) {
        Write-SeatMapResolutionFailureMessage -ResolverError ([string]$resolvedMap.Error)
        exit 1
    }
    if (-not (Test-Path -LiteralPath $SeatMapPath)) {
        Write-SeatMapMissingMessage -Path $SeatMapPath
        exit 1
    }
}
$kitRoot = Resolve-ProbeKitRoot
$taskPath = Get-ProbeTaskPath -TestName $Test -KitRoot $kitRoot
$kitWarning = $null
if ([string]::IsNullOrWhiteSpace($taskPath)) {
    $kitWarning = "Probe kit not found or task '$($taskFiles[$Test])' missing. Set PROBE_KIT_ROOT or place the kit at artifacts/probe-kit."
}

$workDir = Get-ProbeWorkingDirectory -TestName $Test -RepoRoot $repoRoot -KitRoot $kitRoot
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
if ($kitWarning) {
    Write-Host "Task:     (unresolved) $kitWarning"
}
else {
    Write-Host "Task:     $taskPath"
}
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
    Write-Host ("TreeKill: " + (Get-TreeKillCommand -ProcessId ([int]0) -ProcessGroupId ([int]0)))
}

if ($WhatIf) {
    Write-Host 'WhatIf:   validate+resolve+construct complete; launch will not execute.'
    exit 0
}

if ($kitWarning) {
    Write-ProbeError $kitWarning
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

    $workDir = Get-ProbeWorkingDirectory -TestName $Test -RepoRoot $repoRoot -KitRoot $kitRoot -Prepare
    $launch.WorkDir = $workDir
    $launch = New-LaunchSpec -HostName $ProbeHost -Binary $binary -ModelName $Model -TestName $Test -WorkDir $workDir -TaskPath $taskPath

    $run = Invoke-ProbeLaunch -Launch $launch -WaitSeconds $TimeoutSeconds
    $cost = Resolve-CostRecord -TestName $Test -ModelName $Model -StdOut $run.StdOut
    $evidence = if ($run.Cutoff) { 'unmeasured' } else { 'probed' }
    if (-not $run.Cutoff) {
        switch ($Test) {
            'Verdict' { $evidence = Get-VerdictEvidence -StdOut $run.StdOut }
            'Containment' { $evidence = Get-ContainmentEvidence -WorkDir $workDir }
        }
    }
    $metadata = [pscustomobject]@{
        test           = $Test
        cutoff         = $run.Cutoff
        exit           = $run.ExitCode
        processGroupId = $run.ProcessGroupId
    }
    if ($null -ne $run.TreeKill) {
        Set-NoteValue $metadata 'treeKillExit' $run.TreeKill.KillExit
        Set-NoteValue $metadata 'treeKillSurvived' $run.TreeKill.Survived
        if ($run.TreeKill.Survived) {
            Set-NoteValue $metadata 'treeKillFailed' $true
        }
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

    if ($run.Cutoff -or ($null -ne $run.TreeKill -and $run.TreeKill.Survived) -or $evidence -eq 'failed') { exit 1 }
    exit 0
}
finally {
    if ($ProbeHost -eq 'junie') {
        Restore-JunieEffort -Backup $junieBackup -SettingsPath $junieSettings -ModelName $Model
    }
    if ($locked) { Exit-SeatMapLock }
}
