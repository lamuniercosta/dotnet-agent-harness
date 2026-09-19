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

  Set SEAT_MAP_PROBE_FAKE_LAUNCH=1 to write/read back a seat-map cell without
  a billable launch (isolated tests only). Requires an explicit -SeatMapPath;
  the seam refuses the default discovered live map so an ambient env var cannot
  poison workspace state. The fake write uses the same cell fields as a real
  probe write (it does not change activeRung) and stamps metadata.fakeLaunch.
  Evidence is the isolated-test literal `probed` with cost.source `unknown`;
  it is not ambient probe evidence. -WhatIf still wins and does not write.

  OpenCode probes should not run while live OpenCode seats are active: this
  script records ambient reasoning.effort and never edits opencode.jsonc.

  Pre-flight (DEV-236) runs after host/model resolution and before -WhatIf
  exit, seat-map lock, Junie mutation, or launch. Junie missing/unreadable/
  invalid JSON or a missing/non-object effortPerModel fails closed. OpenCode
  warns on stdout when reasoning.effort is set; absent/unreadable/invalid
  config stays non-blocking. Cursor compares cli-config.json with exact
  ordinal trimmed equality and fails closed on conflict or a present
  unreadable/malformed config. Failure messages name path and condition;
  they never echo raw file contents or parser excerpts.

  Kit resolution: $env:PROBE_KIT_ROOT, then <repo>/artifacts/probe-kit.
  A missing kit is an error; the probe will not launch.

  Seat-map writes take a per-canonical-SeatMapPath exclusive FileStream lock
  from _seat-map.ps1 (FileShare.None). A contender fails fast with the literal
  `Seat-map lock held` and does not mutate the map. The lock holder re-reads
  the map inside the critical section before saving. -WhatIf and validation
  failures exit before lock acquisition. Junie settings mutation uses a
  separate process-safe lock on `$HOME/.junie/settings.json`. The OS releases
  both handles when the holder exits; leftover `.lock` files are not PID/stale
  tokens.

.PARAMETER Host
  Canonical platform name. cursor maps to binary agent.

.PARAMETER Model
  Model identifier for the host.

.PARAMETER Test
  Verdict | Containment | Timeout | Edit | Prose | Retrieval | Cost

.PARAMETER Seat
  Seat id or codename. Required with -Rung. Writes that seat-map cell.

.PARAMETER Rung
  Declared rung name from that seat's rungs array. Required with -Seat.

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
if (-not [string]::IsNullOrWhiteSpace($env:PROBE_TIMEOUT_SECONDS)) {
    $parsed = 0
    if ([int]::TryParse($env:PROBE_TIMEOUT_SECONDS, [ref]$parsed)) {
        $TimeoutSeconds = $parsed
    }
}
$JunieProbeEffort = 'high'
# $SeatMapPath is a param; live path is resolved lazily after _seat-map.ps1.

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
        # Caller owns the orphan summary (stderr) + exit behavior so stdout JSON stays parseable.
    }
    return $result
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
            if ($ModelName -like 'deepseek/*') { return 'DEEPSEEK' }
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

function Test-JsonMapObject {
    param(
        [AllowNull()]
        [object]$Value
    )
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [System.ValueType]) { return $false }
    if ($Value -is [System.Array]) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $true }
    if ($Value -is [pscustomobject]) { return $true }
    if ($Value -is [System.Collections.IList]) { return $false }
    return $false
}

function Get-OpenCodeAmbientEffortResult {
    $jsonc = Join-Path (Join-Path (Join-Path $HOME '.config') 'opencode') 'opencode.jsonc'
    $json = Join-Path (Join-Path (Join-Path $HOME '.config') 'opencode') 'opencode.json'
    $configPath = $null
    if (Test-Path -LiteralPath $jsonc) {
        $configPath = $jsonc
    }
    elseif (Test-Path -LiteralPath $json) {
        $configPath = $json
    }
    if ($null -eq $configPath) {
        return [pscustomobject]@{ Status = 'missing'; Path = $null; Effort = $null; Source = $null }
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Status = 'unreadable'; Path = $configPath; Effort = $null; Source = $null }
    }
    if ($null -eq $raw) { $raw = '' }

    try {
        $parsed = ConvertFrom-Jsonc -Raw $raw
    }
    catch {
        return [pscustomobject]@{ Status = 'invalid'; Path = $configPath; Effort = $null; Source = $null }
    }

    $source = $null
    $effort = Get-JsonPath -Object $parsed -Path @('reasoning', 'effort')
    if ($null -ne $effort) {
        $source = 'reasoning.effort'
    }
    else {
        $effort = Get-JsonPath -Object $parsed -Path @('agent', 'reasoning', 'effort')
        if ($null -ne $effort) {
            $source = 'agent.reasoning.effort'
        }
    }
    if ($null -eq $effort) {
        return [pscustomobject]@{ Status = 'absent'; Path = $configPath; Effort = $null; Source = $null }
    }
    return [pscustomobject]@{ Status = 'present'; Path = $configPath; Effort = [string]$effort; Source = $source }
}

function Get-OpenCodeAmbientEffort {
    $result = Get-OpenCodeAmbientEffortResult
    if ($result.Status -ne 'present') { return $null }
    return $result.Effort
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

function Assert-JunieSettingsPreflight {
    $settingsPath = Join-Path (Join-Path $HOME '.junie') 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Write-ProbeError "Junie pre-flight failed: settings file missing: $settingsPath"
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop
    }
    catch {
        Write-ProbeError "Junie pre-flight failed: settings file unreadable: $settingsPath"
    }
    if ($null -eq $raw) { $raw = '' }

    $settings = $null
    try {
        $settings = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-ProbeError "Junie pre-flight failed: settings file is not valid JSON: $settingsPath"
    }

    if (-not (Test-JsonProperty -Object $settings -Name 'effortPerModel')) {
        Write-ProbeError "Junie pre-flight failed: effortPerModel missing: $settingsPath"
    }
    if (-not (Test-JsonMapObject -Value $settings.effortPerModel)) {
        Write-ProbeError "Junie pre-flight failed: effortPerModel is not an object: $settingsPath"
    }
}

function Get-CursorConfiguredModelId {
    param(
        [AllowNull()]
        [object]$Config
    )
    if (-not (Test-JsonMapObject -Value $Config)) {
        return $null
    }

    if (Test-JsonProperty -Object $Config -Name 'model') {
        $model = $Config.model
        if ((Test-JsonMapObject -Value $model) -and (Test-JsonProperty -Object $model -Name 'modelId')) {
            $id = $model.modelId
            if ($id -is [string]) { return $id }
        }
    }

    if (Test-JsonProperty -Object $Config -Name 'selectedModel') {
        $selected = $Config.selectedModel
        if ((Test-JsonMapObject -Value $selected) -and (Test-JsonProperty -Object $selected -Name 'modelId')) {
            $id = $selected.modelId
            if ($id -is [string]) { return $id }
        }
    }

    if (Test-JsonProperty -Object $Config -Name 'model') {
        $model = $Config.model
        if ($model -is [string]) { return $model }
    }

    if (Test-JsonProperty -Object $Config -Name 'selectedModel') {
        $selected = $Config.selectedModel
        if ($selected -is [string]) { return $selected }
    }

    return $null
}

function Assert-CursorModelPreflight {
    param([string]$ProbeModel)
    $configPath = Join-Path (Join-Path $HOME '.cursor') 'cli-config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        return
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
    }
    catch {
        Write-ProbeError "Cursor pre-flight failed: config file unreadable: $configPath"
    }
    if ($null -eq $raw) { $raw = '' }

    $config = $null
    try {
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-ProbeError "Cursor pre-flight failed: config file is not valid JSON: $configPath"
    }

    $configured = Get-CursorConfiguredModelId -Config $config
    if ($null -eq $configured) {
        return
    }

    $left = ([string]$configured).Trim()
    $right = ([string]$ProbeModel).Trim()
    if (-not [string]::Equals($left, $right, [StringComparison]::Ordinal)) {
        Write-ProbeError "Cursor pre-flight failed: configured model conflicts with -Model: $configPath"
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
        Write-SeatMapMissingMessage -Path $MapPath
        exit 1
    }
    $map = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json
    $seatObj = Find-SeatMapSeat -Map $map -Name $SeatName
    if ($null -eq $seatObj) {
        Write-ProbeError "Seat '$SeatName' not found in seat-map.json."
    }
    $cell = Get-SeatMapRungByName -Seat $seatObj -Name $RungName
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
    $exited = $proc.WaitForExit($waitMs)
    if (-not $exited) {
        $cutoff = $true
        $killInfo = Stop-ProbeProcessTree -ProcessId $proc.Id -ProcessGroupId $pgid
        $exited = $proc.WaitForExit(5000)
    }
    $code = -1
    if ($exited) {
        # Guard against ExitCode access when the hung process survives the timeout.
        $code = $proc.ExitCode
    }
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
if ($hasRung -and -not (Test-SeatMapRungName -Name $Rung)) {
    Write-ProbeError "-Rung '$Rung' is not a valid rung name (expected ^[a-z][a-z0-9-]{0,30}$)."
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
    $mapObj = Get-Content -LiteralPath $SeatMapPath -Raw | ConvertFrom-Json
    $mapViolations = @(Get-SeatMapViolations -Map $mapObj)
    if ($mapViolations.Count -gt 0) {
        $mapViolations | ForEach-Object { Write-Error $_ -ErrorAction Continue }
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
$openCodeEffortResult = $null
if ($ProbeHost -eq 'opencode') {
    $openCodeEffortResult = Get-OpenCodeAmbientEffortResult
    if ($openCodeEffortResult.Status -eq 'present') {
        $ambientEffort = $openCodeEffortResult.Effort
    }
}

$resolvedSeat = $null
if ($hasSeat) {
    $resolvedSeat = Resolve-SeatCell -SeatName $Seat -RungName $Rung -MapPath $SeatMapPath
}

# DEV-236: fail-closed Junie/Cursor checks before -WhatIf, lock, mutation, or launch.
if ($ProbeHost -eq 'junie') {
    Assert-JunieSettingsPreflight
}
elseif ($ProbeHost -eq 'cursor') {
    Assert-CursorModelPreflight -ProbeModel $Model
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
        $effortName = if ($openCodeEffortResult -and $openCodeEffortResult.Source) {
            [string]$openCodeEffortResult.Source
        }
        else {
            'reasoning.effort'
        }
        Write-Host "Warning:  $effortName=$ambientEffort is a global/shared OpenCode setting that can affect concurrent OpenCode seats."
    }
    else {
        Write-Host 'Ambient:  reasoning.effort=(unrecorded)'
        if ($openCodeEffortResult -and $openCodeEffortResult.Status -in @('unreadable', 'invalid') -and $openCodeEffortResult.Path) {
            Write-Host "Note:     OpenCode config $($openCodeEffortResult.Status): $($openCodeEffortResult.Path)"
        }
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

function Wait-SeatMapLockBarrierIfRequested {
    # Isolated-test barrier (SEAT_MAP_LOCK_BARRIER_DIR): fake-launch only.
    # Child writes ready, waits for go, then takes the per-map lock so
    # Test-SeatMapLive can force a write into the pre-lock window.
    $barrierDir = [string]$env:SEAT_MAP_LOCK_BARRIER_DIR
    if ([string]::IsNullOrWhiteSpace($barrierDir)) { return }
    $readyPath = Join-Path $barrierDir 'ready'
    $goPath = Join-Path $barrierDir 'go'
    New-Item -ItemType Directory -Path $barrierDir -Force | Out-Null
    [System.IO.File]::WriteAllText($readyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $goPath)) {
        if ([DateTime]::UtcNow -gt $deadline) {
            Write-ProbeError 'SEAT_MAP_LOCK_BARRIER_DIR timed out waiting for go.'
        }
        Start-Sleep -Milliseconds 50
    }
}

$fakeLaunch = [string]$env:SEAT_MAP_PROBE_FAKE_LAUNCH -eq '1'
if ($fakeLaunch) {
    if (-not $hasSeat) {
        Write-ProbeError 'SEAT_MAP_PROBE_FAKE_LAUNCH requires -Seat and -Rung.'
    }
    if (-not $resolvedMap.Explicit) {
        Write-ProbeError 'SEAT_MAP_PROBE_FAKE_LAUNCH requires an explicit -SeatMapPath; it will not write the default live map.'
    }
    Wait-SeatMapLockBarrierIfRequested
    $mapLock = Enter-SeatMapProcessLock -SeatMapPath $SeatMapPath
    try {
        $resolvedSeat = Resolve-SeatCell -SeatName $Seat -RungName $Rung -MapPath $SeatMapPath
        $cost = New-CostRecord -Source 'unknown'
        $evidence = 'probed'
        $metadata = [pscustomobject]@{
            test       = $Test
            fakeLaunch = $true
        }
        Write-SeatCell -Resolved $resolvedSeat -MapPath $SeatMapPath -HostName $ProbeHost -ModelName $Model -Pool $pool -Launch $launch.Command -Evidence $evidence -Cost $cost -Metadata $metadata
        Write-Host "Wrote cell $Seat/$Rung evidence=$evidence cost.source=$($cost.source) (fake launch)"
        exit 0
    }
    finally {
        Exit-SeatMapProcessLock -Handle $mapLock
    }
}

if ($kitWarning) {
    Write-ProbeError $kitWarning
}

$junieSettings = Join-Path (Join-Path $HOME '.junie') 'settings.json'
$junieBackup = $null
$mapLock = $null
$junieLock = $null
try {
    if ($hasSeat) {
        $mapLock = Enter-SeatMapProcessLock -SeatMapPath $SeatMapPath
        $resolvedSeat = Resolve-SeatCell -SeatName $Seat -RungName $Rung -MapPath $SeatMapPath
    }

    if ($ProbeHost -eq 'junie') {
        $junieLock = Enter-ExclusiveFileLock -TargetPath $junieSettings -HeldMessage 'Junie settings lock held'
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

    if ($null -ne $run.TreeKill -and $run.TreeKill.Survived) {
        Write-Error "Probe tree-kill orphan PID $($run.Pid) (process survived kill)." -ErrorAction Continue
    }

    if ($run.Cutoff -or ($null -ne $run.TreeKill -and $run.TreeKill.Survived) -or $evidence -eq 'failed') { exit 1 }
    exit 0
}
finally {
    if ($ProbeHost -eq 'junie') {
        Restore-JunieEffort -Backup $junieBackup -SettingsPath $junieSettings -ModelName $Model
    }
    Exit-ExclusiveFileLock -Handle $junieLock
    Exit-SeatMapProcessLock -Handle $mapLock
}
