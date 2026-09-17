#!/usr/bin/env pwsh
# Bar-proves DEV-239 A1, A3, A5, override precedence, and DEV-237 -Verify
# against an isolated HOME. Does not touch the real user profile's ~/.maestri.
# Cleanup is enforced.
#
#   pwsh -NoProfile ./scripts/local/Test-SeatMapLive.ps1
#
# Path assertions are separator-normalized (no $IsWindows branch, no '\'-only
# expected literals). HOME and USERPROFILE are both set on the child so the
# same probe runs on Windows and Ubuntu.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
$syncScript = Join-Path $PSScriptRoot 'Sync-SeatMap.ps1'
$testSeatMap = Join-Path $PSScriptRoot 'Test-SeatMap.ps1'
$probeScript = Join-Path $PSScriptRoot 'Test-ModelProbe.ps1'
$serverScript = Join-Path $PSScriptRoot 'Start-SeatMapServer.ps1'
$examplePath = Join-Path $PSScriptRoot 'seat-map.example.json'
$helperPath = Join-Path $PSScriptRoot '_seat-map.ps1'
. $helperPath

$checks = 0
$failures = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Expected = '', [string]$Actual = '')
    $script:checks++
    if ($Condition) {
        Write-Host "  ok       $Name"
    }
    else {
        Write-Host "  FAIL     $Name" -ForegroundColor Red
        if ($Expected -ne '' -or $Actual -ne '') {
            Write-Host "           expected=$Expected" -ForegroundColor DarkGray
            Write-Host "           actual  =$Actual" -ForegroundColor DarkGray
        }
        $script:failures++
    }
}

function ConvertTo-Fwd {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '/')
}

function Test-TextContains {
    param([string]$Haystack, [string]$Needle)
    return (ConvertTo-Fwd $Haystack).Contains((ConvertTo-Fwd $Needle))
}

function Assert-VerifyOutputRedacted {
    param(
        [string]$Name,
        [string]$Combined,
        [string]$WorkspaceJsonPath
    )
    Assert-True "$Name : no C:\Users\" (-not (Test-TextContains $Combined 'C:\Users\')) 'absent C:\Users\' $Combined
    Assert-True "$Name : no `$HOME literal" (-not (Test-TextContains $Combined '$HOME')) 'absent $HOME' $Combined
    Assert-True "$Name : no full workspace.json path" (-not (Test-TextContains $Combined $WorkspaceJsonPath)) "absent $WorkspaceJsonPath" $Combined
}

function Get-Porcelain {
    $raw = & git -C $repoRoot status --porcelain 2>&1
    if ($null -eq $raw) { return '' }
    return (@($raw) | ForEach-Object { "$_" }) -join "`n"
}

function Invoke-IsolatedPwsh {
    param(
        [Parameter(Mandatory)][string]$HomeDir,
        [Parameter(Mandatory)][string]$File,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutMs = 120000
    )
    $pwsh = (Get-Command pwsh).Source
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot
    [void]$psi.ArgumentList.Add('-NoProfile')
    [void]$psi.ArgumentList.Add('-File')
    [void]$psi.ArgumentList.Add($File)
    foreach ($a in $ArgumentList) {
        [void]$psi.ArgumentList.Add([string]$a)
    }
    $psi.Environment['HOME'] = $HomeDir
    $psi.Environment['USERPROFILE'] = $HomeDir
    $psi.Environment['MAESTRI_PIPE'] = ''

    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill($true) } catch { }
        [void]$p.WaitForExit(5000)
        return [pscustomobject]@{
            ExitCode = 124
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $true
        }
    }
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $stdoutTask.GetAwaiter().GetResult()
        StdErr   = $stderrTask.GetAwaiter().GetResult()
        TimedOut = $false
    }
}

function New-WorkspaceDir {
    param(
        [string]$HomeDir,
        [string]$WorkspaceId,
        [string]$RepoRootHint
    )
    $wsDir = Join-Path $HomeDir '.maestri' 'workspaces' $WorkspaceId
    New-Item -ItemType Directory -Path $wsDir -Force | Out-Null
    $wj = Join-Path $wsDir 'workspace.json'
    $payload = @{ repoRoot = $RepoRootHint } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($wj, $payload + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    return $wsDir
}

function Get-HeadLaunchRecords {
    param([Parameter(Mandatory)][string]$SeatMapPath)
    $map = Get-Content -LiteralPath $SeatMapPath -Raw | ConvertFrom-Json
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($map.seats)) {
        $head = Get-SeatMapRungByRole -Seat $s -Role 'head'
        $launch = ''
        if ($null -ne $head -and (Test-JsonProperty -Object $head -Name 'launch')) {
            $launch = [string]$head.launch
        }
        $roleId = if (Test-JsonProperty -Object $s -Name 'roleId') { [string]$s.roleId } else { '' }
        $code = if (Test-JsonProperty -Object $s -Name 'codename') { [string]$s.codename } else { [string]$s.id }
        $out.Add([pscustomobject]@{
            Codename       = $code
            AssignedRoleId = $roleId
            Command        = $launch
        })
    }
    return @($out)
}

function Write-WorkspaceVerifyJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RepoRootHint,
        [AllowEmptyCollection()][object[]]$Terminals = @()
    )
    $nodes = [System.Collections.Generic.List[object]]::new()
    $nodes.Add([ordered]@{
            content = [ordered]@{
                note = [ordered]@{ text = 'ignored-non-terminal' }
            }
        })
    foreach ($t in @($Terminals)) {
        if ($null -eq $t) { continue }
        if ([bool](Test-JsonProperty -Object $t -Name 'OmitTerminal') -and [bool]$t.OmitTerminal) { continue }
        if ([bool](Test-JsonProperty -Object $t -Name 'Missing0') -and [bool]$t.Missing0) {
            $nodes.Add([ordered]@{
                    content = [ordered]@{ terminal = [ordered]@{} }
                })
            continue
        }
        $inner = [ordered]@{}
        $missingRole = [bool](Test-JsonProperty -Object $t -Name 'MissingRoleId') -and [bool]$t.MissingRoleId
        $missingCmd = [bool](Test-JsonProperty -Object $t -Name 'MissingCommand') -and [bool]$t.MissingCommand
        if (-not $missingRole) {
            $inner['assignedRoleId'] = [string]$t.AssignedRoleId
        }
        if (-not $missingCmd) {
            $inner['command'] = [string]$t.Command
        }
        $nodes.Add([ordered]@{
                content = [ordered]@{
                    terminal = [ordered]@{
                        '_0' = $inner
                    }
                }
            })
    }
    $obj = [ordered]@{
        repoRoot = $RepoRootHint
        payload  = [ordered]@{ nodes = @($nodes) }
    }
    $json = $obj | ConvertTo-Json -Depth 8
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Write-MatchingWorkspaceVerifyJson {
    param(
        [Parameter(Mandatory)][string]$WsDir,
        [string]$RepoRootHint,
        [Parameter(Mandatory)][string]$SeatMapPath,
        [object[]]$Terminals
    )
    $wj = Join-Path $WsDir 'workspace.json'
    $rows = if ($null -ne $Terminals) { @($Terminals) } else { @(Get-HeadLaunchRecords -SeatMapPath $SeatMapPath) }
    Write-WorkspaceVerifyJson -Path $wj -RepoRootHint $RepoRootHint -Terminals $rows
}

function Get-RecursiveFileSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return '<missing>' }
    $items = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'StartupProfileData-*' } |
            Sort-Object FullName
    )
    $lines = foreach ($f in $items) {
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        '{0}|{1}|{2}' -f $rel.Replace('\', '/'), $hash, $f.Length
    }
    return (($lines | ForEach-Object { $_ }) -join "`n")
}

function Get-TargetedMaestriSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return '<missing>' }
    $want = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @('workspace.json', 'seat-map.json', 'harness-team-charter.md', 'team-restart.md', 'seat-map-swaps.jsonl', 'role.json')) {
        [void]$want.Add($n)
    }
    $items = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $want.Contains($_.Name) } |
            Sort-Object FullName
    )
    $lines = foreach ($f in $items) {
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        '{0}|{1}|{2}' -f $rel.Replace('\', '/'), $hash, $f.Length
    }
    return (($lines | ForEach-Object { $_ }) -join "`n")
}

function Write-NoteStubs {
    param([string]$WsDir)
    $notes = Join-Path $WsDir 'notes'
    New-Item -ItemType Directory -Path $notes -Force | Out-Null
    $charter = @(
        '| Seat | Codename | Agent + model (active) | Pool |',
        '|---|---|---|---|',
        '| x | y | z | p |',
        ''
    ) -join "`n"
    $restart = @(
        '| Seat | Launch command |',
        '| --- | --- |',
        '| x | `y` |',
        ''
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $notes 'harness-team-charter.md'), $charter + "`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $notes 'team-restart.md'), $restart + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Test-BindTimeThrow {
    param([string]$StdOut, [string]$StdErr)
    $blob = "$StdOut`n$StdErr"
    return [bool]($blob -match 'ParameterBindingException|ParameterBindingValidationException')
}

function Get-PrimaryWorktreePath {
    param([string]$RepoRoot)
    $porcelain = & git -C $RepoRoot worktree list --porcelain 2>$null
    foreach ($line in @($porcelain)) {
        if ([string]$line -match '^worktree\s+(.+)$') {
            return $Matches[1]
        }
    }
    return $RepoRoot
}

function Install-RoleFixtures {
    param([string]$RepoRoot, [string]$ExamplePath)
    $rolesDir = Join-Path $RepoRoot '.maestri' 'roles'
    New-Item -ItemType Directory -Path $rolesDir -Force | Out-Null
    $map = Get-Content -LiteralPath $ExamplePath -Raw | ConvertFrom-Json
    $created = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($map.seats)) {
        $dir = Join-Path $rolesDir $s.roleId
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'role.json'
        $headCell = if (Test-JsonProperty -Object $s.rungs -Name 'head') { $s.rungs.head } else { $null }
        $thenCell = if (Test-JsonProperty -Object $s.rungs -Name 'then') { $s.rungs.then } else { $null }
        $floorCell = if (Test-JsonProperty -Object $s.rungs -Name 'floor') { $s.rungs.floor } else { $null }
        $headL = if ($null -ne $headCell) { [string]$headCell.launch } else { '' }
        $thenL = if ($null -ne $thenCell) { [string]$thenCell.launch } else { '' }
        $floorL = if ($null -ne $floorCell) { [string]$floorCell.launch } else { '' }
        $obj = [ordered]@{
            prompt = "Model chain (best first): $headL -> $thenL -> $floorL (FLOOR)."
        }
        $json = $obj | ConvertTo-Json -Depth 4
        if (-not $json.EndsWith("`n")) { $json += "`n" }
        [System.IO.File]::WriteAllText($file, $json, [System.Text.UTF8Encoding]::new($false))
        $created.Add($file)
    }
    return $created
}

$realProfile = [Environment]::GetFolderPath('UserProfile')
$realMaestri = Join-Path $realProfile '.maestri'
$realSwapLog = Join-Path $realMaestri 'seat-map-swaps.jsonl'
$realSwapExistsBefore = Test-Path -LiteralPath $realSwapLog
$realSwapWriteBefore = $null
$realSwapLenBefore = 0
if ($realSwapExistsBefore) {
    $item = Get-Item -LiteralPath $realSwapLog
    $realSwapWriteBefore = $item.LastWriteTimeUtc
    $realSwapLenBefore = $item.Length
}

$realMaestriSnapBefore = Get-TargetedMaestriSnapshot -Root $realMaestri

$isoHome = Join-Path ([System.IO.Path]::GetTempPath()) ('seat-map-live-' + [guid]::NewGuid().ToString('N'))
if ([string]::Equals((ConvertTo-Fwd $isoHome).TrimEnd('/'), (ConvertTo-Fwd $realProfile).TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to isolate HOME onto the real user profile: $isoHome"
}

$worktreeMaestri = Join-Path $repoRoot '.maestri'
$worktreeRoles = Join-Path $worktreeMaestri 'roles'
$hadWorktreeMaestri = Test-Path -LiteralPath $worktreeMaestri
$hadWorktreeRoles = Test-Path -LiteralPath $worktreeRoles
$dev234AnvilRoleFile = $null
$dev234AnvilRoleHadFile = $false
$dev234AnvilRolePriorBytes = $null
$dev234AnvilRoleDirExisted = $false

Write-Host 'Test-SeatMapLive (isolated HOME)'

try {
    New-Item -ItemType Directory -Path $isoHome -Force | Out-Null
    [void](Install-RoleFixtures -RepoRoot $repoRoot -ExamplePath $examplePath)

    Assert-True 'example file exists' (Test-Path -LiteralPath $examplePath) $examplePath 'missing'

    $wsId = [guid]::NewGuid().ToString()
    $wsDir = New-WorkspaceDir -HomeDir $isoHome -WorkspaceId $wsId -RepoRootHint $repoRoot
    Write-NoteStubs -WsDir $wsDir
    $livePath = Join-Path $wsDir 'seat-map.json'

    # --- A5 missing target ---
    $missing = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Validate')
    Assert-True 'A5 missing: exit 1' ($missing.ExitCode -eq 1) '1' ([string]$missing.ExitCode)
    Assert-True 'A5 missing: stderr names expected path' (Test-TextContains $missing.StdErr $livePath) $livePath $missing.StdErr
    Assert-True 'A5 missing: stderr names Init' (Test-TextContains $missing.StdErr 'Init') 'Init' $missing.StdErr
    Assert-True 'A5 missing: no bind-time throw' (-not (Test-BindTimeThrow $missing.StdOut $missing.StdErr)) 'no ParameterBindingException' "$($missing.StdOut)$($missing.StdErr)"

    $missingTest = Invoke-IsolatedPwsh -HomeDir $isoHome -File $testSeatMap
    Assert-True 'A5 Test-SeatMap missing: exit 1' ($missingTest.ExitCode -eq 1) '1' ([string]$missingTest.ExitCode)
    Assert-True 'A5 Test-SeatMap missing: stderr names Init' (Test-TextContains $missingTest.StdErr 'Init') 'Init' $missingTest.StdErr
    Assert-True 'A5 Test-SeatMap missing: stderr names path' (Test-TextContains $missingTest.StdErr $livePath) $livePath $missingTest.StdErr

    $missingServer = Invoke-IsolatedPwsh -HomeDir $isoHome -File $serverScript -TimeoutMs 15000
    Assert-True 'A5 Start-SeatMapServer missing: exit 1' ($missingServer.ExitCode -eq 1) '1' ([string]$missingServer.ExitCode)
    Assert-True 'A5 Start-SeatMapServer missing: stderr names expected path' (Test-TextContains $missingServer.StdErr $livePath) $livePath $missingServer.StdErr
    Assert-True 'A5 Start-SeatMapServer missing: stderr names Init' (Test-TextContains $missingServer.StdErr 'Init') 'Init' $missingServer.StdErr
    Assert-True 'A5 Start-SeatMapServer did not hang' (-not $missingServer.TimedOut) 'TimedOut=false' ([string]$missingServer.TimedOut)

    # --- A5 -Init copies example byte-for-byte ---
    $initLiteral = 'Creating from example; not restoring previous state. Swap log: ~/.maestri/seat-map-swaps.jsonl'
    $init = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Init')
    Assert-True 'A5 -Init missing: exit 0' ($init.ExitCode -eq 0) '0' ([string]$init.ExitCode)
    Assert-True 'A5 -Init missing: creating-from-example literal' (Test-TextContains $init.StdOut $initLiteral) $initLiteral $init.StdOut
    Assert-True 'A5 -Init missing: live file exists' (Test-Path -LiteralPath $livePath) $livePath 'missing'
    $exampleHash = (Get-FileHash -LiteralPath $examplePath -Algorithm SHA256).Hash
    $liveHash = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash
    Assert-True 'A5 -Init missing: destination byte-equal to example' ($exampleHash -eq $liveHash) $exampleHash $liveHash

    # --- A5 existing target refused ---
    $refuse = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Init')
    Assert-True 'A5 -Init existing: exit non-zero' ($refuse.ExitCode -ne 0) 'non-zero' ([string]$refuse.ExitCode)
    $afterRefuseHash = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash
    Assert-True 'A5 -Init existing: target left unchanged' ($afterRefuseHash -eq $liveHash) $liveHash $afterRefuseHash

    # --- A1 no-arg -Validate ---
    $a1 = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Validate')
    $a1At = "Validating seat map at: $livePath"
    Assert-True 'A1: exit 0' ($a1.ExitCode -eq 0) '0' ([string]$a1.ExitCode)
    Assert-True 'A1: Validating seat map at: <resolved-path>' (Test-TextContains $a1.StdOut $a1At) $a1At $a1.StdOut
    Assert-True 'A1: resolved workspace id' (Test-TextContains $a1.StdOut $wsId) $wsId $a1.StdOut

    # --- positive worktree/default: workspace.json names the primary checkout ---
    $primaryRoot = Get-PrimaryWorktreePath -RepoRoot $repoRoot
    $wtHome = Join-Path $isoHome 'worktree-default'
    $wtWsId = [guid]::NewGuid().ToString()
    $wtWsDir = New-WorkspaceDir -HomeDir $wtHome -WorkspaceId $wtWsId -RepoRootHint $primaryRoot
    Write-NoteStubs -WsDir $wtWsDir
    $wtLivePath = Join-Path $wtWsDir 'seat-map.json'
    Copy-Item -LiteralPath $examplePath -Destination $wtLivePath
    $wtDefault = Invoke-IsolatedPwsh -HomeDir $wtHome -File $syncScript -ArgumentList @('-Validate')
    $wtAt = "Validating seat map at: $wtLivePath"
    Assert-True 'worktree/default: exit 0' ($wtDefault.ExitCode -eq 0) '0' ([string]$wtDefault.ExitCode)
    Assert-True 'worktree/default: Validating seat map at: <livePath>' (Test-TextContains $wtDefault.StdOut $wtAt) $wtAt $wtDefault.StdOut
    Assert-True 'worktree/default: resolved workspace id' (Test-TextContains $wtDefault.StdOut $wtWsId) $wtWsId $wtDefault.StdOut

    # --- override: explicit -SeatMapPath beats workspace discovery ---
    Remove-Item -LiteralPath $livePath -Force
    $overridePath = Join-Path $isoHome 'explicit-seat-map.json'
    Copy-Item -LiteralPath $examplePath -Destination $overridePath
    $override = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Validate', '-SeatMapPath', $overridePath)
    Assert-True 'override Sync: exit 0 while live map missing' ($override.ExitCode -eq 0) '0' ([string]$override.ExitCode)
    Assert-True 'override Sync: output names explicit path' (Test-TextContains $override.StdOut $overridePath) $overridePath $override.StdOut
    Assert-True 'override Sync: output does not name live path' (-not (Test-TextContains $override.StdOut $livePath)) "not $livePath" $override.StdOut

    $probeOverride = Invoke-IsolatedPwsh -HomeDir $isoHome -File $probeScript -ArgumentList @(
        '-Host', 'cursor',
        '-Model', 'composer-2.5',
        '-Test', 'Verdict',
        '-Seat', 'conductor',
        '-Rung', 'floor',
        '-WhatIf',
        '-SeatMapPath', $overridePath
    )
    Assert-True 'override ModelProbe: exit 0 while live map missing' ($probeOverride.ExitCode -eq 0) '0' ("exit=$($probeOverride.ExitCode)`n$($probeOverride.StdOut)`n$($probeOverride.StdErr)")
    Assert-True 'override ModelProbe: no A5 Init in stderr' (-not (Test-TextContains $probeOverride.StdErr 'Init')) 'no Init' $probeOverride.StdErr

    # Restore live map for A3.
    Copy-Item -LiteralPath $examplePath -Destination $livePath

    # --- DEV-237 -Verify workspace drift ---
    $anvilRoleId = 'BA23D857-A79B-4128-B154-8D05C3D5DC31'
    $cogRoleId = '1E272DA5-EB12-4E33-8A46-5D5579AB066C'
    $anvilLaunch = 'agent --model cursor-grok-4.6-high --trust'
    $cogLaunch = 'agy --model gemini-3.6-flash-low --dangerously-skip-permissions'
    $anvilDriftLaunch = 'agent --model drifted --trust'
    $anvilMatch = "[VERIFY MATCH] Anvil roleId=$anvilRoleId"
    $cogMatch = "[VERIFY MATCH] Cog roleId=$cogRoleId"
    $anvilDrift = "[VERIFY DRIFT] Anvil roleId=$anvilRoleId"
    $cogMissing = "[VERIFY MISSING] Cog roleId=$cogRoleId no terminal with assignedRoleId"
    $anvilDup = "[VERIFY ERROR] Anvil roleId=$anvilRoleId duplicate terminals for assignedRoleId"
    $malformedLiteral = '[VERIFY ERROR] workspace terminal payload malformed'
    $zeroLiteral = '[VERIFY ERROR] no terminal records found in workspace.json'
    $exampleRaw = Get-Content -LiteralPath $examplePath -Raw
    Assert-True 'DEV-237 fixture Anvil roleId' (Test-TextContains $exampleRaw $anvilRoleId) $anvilRoleId 'missing'
    Assert-True 'DEV-237 fixture Anvil head launch' (Test-TextContains $exampleRaw $anvilLaunch) $anvilLaunch 'missing'
    Assert-True 'DEV-237 fixture Cog roleId' (Test-TextContains $exampleRaw $cogRoleId) $cogRoleId 'missing'
    Assert-True 'DEV-237 fixture Cog head launch' (Test-TextContains $exampleRaw $cogLaunch) $cogLaunch 'missing'
    Assert-True 'DEV-237 path compare has no $IsWindows branch' (Test-TextContains 'a\b\c' 'a/b/c') 'a/b/c' 'separator-normalized'

    $matchRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath)
    $matchRecords += [pscustomobject]@{
        AssignedRoleId = '00000000-0000-0000-0000-000000000000'
        Command        = 'orphan-should-be-ignored'
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $matchRecords

    $isoMaestri = Join-Path $isoHome '.maestri'
    $homeBeforeVerify = Get-RecursiveFileSnapshot -Root $isoMaestri
    $porcelainBeforeVerify = Get-Porcelain
    $realBeforeVerify = Get-TargetedMaestriSnapshot -Root $realMaestri
    $verifyOk = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $homeAfterVerify = Get-RecursiveFileSnapshot -Root $isoMaestri
    $porcelainAfterVerify = Get-Porcelain
    $realAfterVerify = Get-TargetedMaestriSnapshot -Root $realMaestri
    $verifyOkCombined = "$($verifyOk.StdOut)`n$($verifyOk.StdErr)"
    Assert-True 'DEV-237 success: exit 0' ($verifyOk.ExitCode -eq 0) '0' ("exit=$($verifyOk.ExitCode)`n$verifyOkCombined")
    Assert-True 'DEV-237 success: Anvil MATCH on stdout' (Test-TextContains $verifyOk.StdOut $anvilMatch) $anvilMatch $verifyOk.StdOut
    Assert-True 'DEV-237 success: Cog MATCH on stdout' (Test-TextContains $verifyOk.StdOut $cogMatch) $cogMatch $verifyOk.StdOut
    Assert-True 'DEV-237 success: VERIFY OK: on stdout' (Test-TextContains $verifyOk.StdOut 'VERIFY OK:') 'VERIFY OK:' $verifyOk.StdOut
    Assert-True 'DEV-237 success: Anvil launch redacted' (-not (Test-TextContains $verifyOkCombined $anvilLaunch)) "absent $anvilLaunch" $verifyOkCombined
    Assert-True 'DEV-237 success: Cog launch redacted' (-not (Test-TextContains $verifyOkCombined $cogLaunch)) "absent $cogLaunch" $verifyOkCombined
    Assert-True 'DEV-237 read-only: git porcelain unchanged' ($porcelainBeforeVerify -eq $porcelainAfterVerify) $porcelainBeforeVerify $porcelainAfterVerify
    Assert-True 'DEV-237 read-only: isolated HOME snapshot unchanged' ($homeBeforeVerify -eq $homeAfterVerify) $homeBeforeVerify $homeAfterVerify
    Assert-True 'DEV-237 read-only: real .maestri targeted snapshot unchanged' ($realBeforeVerify -eq $realAfterVerify) $realBeforeVerify $realAfterVerify

    $unassignedRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath)
    $unassignedRecords += [pscustomobject]@{
        AssignedRoleId = ''
        Command        = 'operator-unassigned-terminal'
        MissingRoleId  = $true
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $unassignedRecords
    $verifyUnassigned = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyUnassignedCombined = "$($verifyUnassigned.StdOut)`n$($verifyUnassigned.StdErr)"
    Assert-True 'DEV-237 unassigned terminal: exit 0' ($verifyUnassigned.ExitCode -eq 0) '0' ("exit=$($verifyUnassigned.ExitCode)`n$verifyUnassignedCombined")
    Assert-True 'DEV-237 unassigned terminal: no malformed abort' (-not (Test-TextContains $verifyUnassignedCombined $malformedLiteral)) "absent $malformedLiteral" $verifyUnassignedCombined
    Assert-True 'DEV-237 unassigned terminal: Anvil MATCH' (Test-TextContains $verifyUnassigned.StdOut $anvilMatch) $anvilMatch $verifyUnassigned.StdOut
    Assert-True 'DEV-237 unassigned terminal: Cog MATCH' (Test-TextContains $verifyUnassigned.StdOut $cogMatch) $cogMatch $verifyUnassigned.StdOut
    Assert-True 'DEV-237 unassigned terminal: VERIFY OK:' (Test-TextContains $verifyUnassigned.StdOut 'VERIFY OK:') 'VERIFY OK:' $verifyUnassigned.StdOut

    $crlfRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath)
    foreach ($row in $crlfRecords) {
        if ($row.AssignedRoleId -eq $anvilRoleId) {
            $row.Command = $anvilLaunch + "`r`n"
        }
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $crlfRecords
    $verifyCrlf = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyCrlfCombined = "$($verifyCrlf.StdOut)`n$($verifyCrlf.StdErr)"
    Assert-True 'DEV-237 trailing CR/LF: exit 0' ($verifyCrlf.ExitCode -eq 0) '0' ("exit=$($verifyCrlf.ExitCode)`n$verifyCrlfCombined")
    Assert-True 'DEV-237 trailing CR/LF: Anvil MATCH' (Test-TextContains $verifyCrlf.StdOut $anvilMatch) $anvilMatch $verifyCrlf.StdOut

    $driftRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath)
    foreach ($row in $driftRecords) {
        if ($row.AssignedRoleId -eq $anvilRoleId) { $row.Command = $anvilDriftLaunch }
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $driftRecords
    $verifyDrift = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyDriftCombined = "$($verifyDrift.StdOut)`n$($verifyDrift.StdErr)"
    Assert-True 'DEV-237 drift: exit 1' ($verifyDrift.ExitCode -eq 1) '1' ("exit=$($verifyDrift.ExitCode)`n$verifyDriftCombined")
    Assert-True 'DEV-237 drift: Anvil DRIFT' (Test-TextContains $verifyDriftCombined $anvilDrift) $anvilDrift $verifyDriftCombined
    Assert-True 'DEV-237 drift: VERIFY FAILED:' (Test-TextContains $verifyDriftCombined 'VERIFY FAILED:') 'VERIFY FAILED:' $verifyDriftCombined
    Assert-True 'DEV-237 drift: expected launch redacted' (-not (Test-TextContains $verifyDriftCombined $anvilLaunch)) "absent $anvilLaunch" $verifyDriftCombined
    Assert-True 'DEV-237 drift: actual launch redacted' (-not (Test-TextContains $verifyDriftCombined $anvilDriftLaunch)) "absent $anvilDriftLaunch" $verifyDriftCombined
    Assert-VerifyOutputRedacted -Name 'DEV-237 drift final failure' -Combined $verifyDriftCombined -WorkspaceJsonPath (Join-Path $wsDir 'workspace.json')

    $missingRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath | Where-Object { $_.AssignedRoleId -ne $cogRoleId })
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $missingRecords
    $verifyMissing = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyMissingCombined = "$($verifyMissing.StdOut)`n$($verifyMissing.StdErr)"
    Assert-True 'DEV-237 missing terminal: exit 1' ($verifyMissing.ExitCode -eq 1) '1' ("exit=$($verifyMissing.ExitCode)`n$verifyMissingCombined")
    Assert-True 'DEV-237 missing terminal: Cog MISSING' (Test-TextContains $verifyMissingCombined $cogMissing) $cogMissing $verifyMissingCombined

    $dupRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(Get-HeadLaunchRecords -SeatMapPath $livePath)) {
        $dupRecords.Add($row)
        if ($row.AssignedRoleId -eq $anvilRoleId) { $dupRecords.Add($row) }
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals @($dupRecords)
    $verifyDup = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyDupCombined = "$($verifyDup.StdOut)`n$($verifyDup.StdErr)"
    Assert-True 'DEV-237 duplicate terminal: exit 1' ($verifyDup.ExitCode -eq 1) '1' ("exit=$($verifyDup.ExitCode)`n$verifyDupCombined")
    Assert-True 'DEV-237 duplicate terminal: Anvil ERROR' (Test-TextContains $verifyDupCombined $anvilDup) $anvilDup $verifyDupCombined

    $malformedRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath)
    $malformedRecords += [pscustomobject]@{
        AssignedRoleId = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'
        Command        = 'unused'
        MissingCommand = $true
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $malformedRecords
    $verifyMalformed = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyMalformedCombined = "$($verifyMalformed.StdOut)`n$($verifyMalformed.StdErr)"
    Assert-True 'DEV-237 malformed payload: exit 1' ($verifyMalformed.ExitCode -eq 1) '1' ("exit=$($verifyMalformed.ExitCode)`n$verifyMalformedCombined")
    Assert-True 'DEV-237 malformed payload: ERROR' (Test-TextContains $verifyMalformedCombined $malformedLiteral) $malformedLiteral $verifyMalformedCombined
    Assert-True 'DEV-237 malformed payload: no seat DRIFT' (-not (Test-TextContains $verifyMalformedCombined '[VERIFY DRIFT]')) 'no [VERIFY DRIFT]' $verifyMalformedCombined

    Write-WorkspaceVerifyJson -Path (Join-Path $wsDir 'workspace.json') -RepoRootHint $repoRoot -Terminals @()
    $verifyZero = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyZeroCombined = "$($verifyZero.StdOut)`n$($verifyZero.StdErr)"
    Assert-True 'DEV-237 zero terminals: exit 1' ($verifyZero.ExitCode -eq 1) '1' ("exit=$($verifyZero.ExitCode)`n$verifyZeroCombined")
    Assert-True 'DEV-237 zero terminals: ERROR' (Test-TextContains $verifyZeroCombined $zeroLiteral) $zeroLiteral $verifyZeroCombined

    $wjPath = Join-Path $wsDir 'workspace.json'
    $wjBackup = [System.IO.File]::ReadAllBytes($wjPath)
    $missingWsLiteral = "Verify workspace.json not found for workspaceId=$wsId"
    Remove-Item -LiteralPath $wjPath -Force
    $verifyMissingWs = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify', '-WorkspaceId', $wsId)
    $verifyMissingWsCombined = "$($verifyMissingWs.StdOut)`n$($verifyMissingWs.StdErr)"
    Assert-True 'DEV-237 missing workspace.json: exit 1' ($verifyMissingWs.ExitCode -eq 1) '1' ("exit=$($verifyMissingWs.ExitCode)`n$verifyMissingWsCombined")
    Assert-True 'DEV-237 missing workspace.json: workspaceId wording' (Test-TextContains $verifyMissingWsCombined $missingWsLiteral) $missingWsLiteral $verifyMissingWsCombined
    Assert-VerifyOutputRedacted -Name 'DEV-237 missing workspace.json' -Combined $verifyMissingWsCombined -WorkspaceJsonPath $wjPath
    [System.IO.File]::WriteAllBytes($wjPath, $wjBackup)

    $unreadableLiteral = "Verify workspace.json unreadable for workspaceId=$wsId"
    [System.IO.File]::WriteAllText($wjPath, '{ not-json', [System.Text.UTF8Encoding]::new($false))
    $verifyUnreadable = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify', '-WorkspaceId', $wsId)
    $verifyUnreadableCombined = "$($verifyUnreadable.StdOut)`n$($verifyUnreadable.StdErr)"
    Assert-True 'DEV-237 unreadable workspace.json: exit 1' ($verifyUnreadable.ExitCode -eq 1) '1' ("exit=$($verifyUnreadable.ExitCode)`n$verifyUnreadableCombined")
    Assert-True 'DEV-237 unreadable workspace.json: workspaceId wording' (Test-TextContains $verifyUnreadableCombined $unreadableLiteral) $unreadableLiteral $verifyUnreadableCombined
    Assert-VerifyOutputRedacted -Name 'DEV-237 unreadable workspace.json' -Combined $verifyUnreadableCombined -WorkspaceJsonPath $wjPath
    [System.IO.File]::WriteAllBytes($wjPath, $wjBackup)

    $accumRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath | Where-Object { $_.AssignedRoleId -ne $cogRoleId })
    foreach ($row in $accumRecords) {
        if ($row.AssignedRoleId -eq $anvilRoleId) { $row.Command = $anvilDriftLaunch }
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $accumRecords
    $verifyAccum = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify')
    $verifyAccumCombined = "$($verifyAccum.StdOut)`n$($verifyAccum.StdErr)"
    Assert-True 'DEV-237 multi-seat: exit 1' ($verifyAccum.ExitCode -eq 1) '1' ("exit=$($verifyAccum.ExitCode)`n$verifyAccumCombined")
    Assert-True 'DEV-237 multi-seat: Anvil DRIFT' (Test-TextContains $verifyAccumCombined $anvilDrift) $anvilDrift $verifyAccumCombined
    Assert-True 'DEV-237 multi-seat: Cog MISSING' (Test-TextContains $verifyAccumCombined $cogMissing) $cogMissing $verifyAccumCombined
    Assert-True 'DEV-237 multi-seat: VERIFY FAILED:' (Test-TextContains $verifyAccumCombined 'VERIFY FAILED:') 'VERIFY FAILED:' $verifyAccumCombined

    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath

    # --- A3 porcelain unchanged after Sync -All and probe -WhatIf ---
    $porcelainBefore = Get-Porcelain
    $all = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-All')
    $whatIf = Invoke-IsolatedPwsh -HomeDir $isoHome -File $probeScript -ArgumentList @(
        '-Host', 'cursor',
        '-Model', 'composer-2.5',
        '-Test', 'Verdict',
        '-WhatIf'
    )
    $porcelainAfter = Get-Porcelain
    $allCombined = "$($all.StdOut)`n$($all.StdErr)"
    Assert-True 'A3: Sync -All exit 0' ($all.ExitCode -eq 0) '0' ("exit=$($all.ExitCode)`n$allCombined")
    Assert-True 'A3: Test-ModelProbe -WhatIf exit 0' ($whatIf.ExitCode -eq 0) '0' ([string]$whatIf.ExitCode)
    Assert-True 'A3: git status --porcelain unchanged by Sync -All and probe -WhatIf' ($porcelainBefore -eq $porcelainAfter) $porcelainBefore $porcelainAfter
    if ([string]::IsNullOrWhiteSpace($porcelainBefore)) {
        Assert-True 'A3: git status --porcelain empty' ([string]::IsNullOrWhiteSpace($porcelainAfter)) '(empty)' $porcelainAfter
    }
    else {
        Write-Host "           (worktree already dirty; A3 empty-porcelain is the unchanged snapshot)" -ForegroundColor DarkGray
    }
    # Portal-swap live-server leg is a post-merge manual step; same write helper.

    $allDriftRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath)
    foreach ($row in $allDriftRecords) {
        if ($row.AssignedRoleId -eq $anvilRoleId) { $row.Command = $anvilDriftLaunch }
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $allDriftRecords
    $allDrift = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-All')
    $allDriftCombined = "$($allDrift.StdOut)`n$($allDrift.StdErr)"
    Assert-True 'DEV-237 -All drift: exit 1' ($allDrift.ExitCode -eq 1) '1' ("exit=$($allDrift.ExitCode)`n$allDriftCombined")
    Assert-True 'DEV-237 -All drift: partial-write receipt' (Test-TextContains $allDriftCombined 'Sync phases completed before verify failure; workspace drift remains.') 'Sync phases completed before verify failure; workspace drift remains.' $allDriftCombined
    Assert-True 'DEV-237 -All drift: VERIFY DRIFT' (Test-TextContains $allDriftCombined '[VERIFY DRIFT]') '[VERIFY DRIFT]' $allDriftCombined
    Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath

    $completedReceipt = 'Sync phases completed before verify failure; workspace drift remains.'
    $cogRoleFile = Join-Path $repoRoot '.maestri' 'roles' $cogRoleId 'role.json'
    $anvilRoleFileForCombo = Join-Path $repoRoot '.maestri' 'roles' $anvilRoleId 'role.json'
    $cogRoleHadFile = Test-Path -LiteralPath $cogRoleFile
    $cogRolePriorBytes = $null
    $anvilRoleComboBytes = $null
    if (Test-Path -LiteralPath $anvilRoleFileForCombo) {
        $anvilRoleComboBytes = [System.IO.File]::ReadAllBytes($anvilRoleFileForCombo)
    }
    if ($cogRoleHadFile) {
        $cogRolePriorBytes = [System.IO.File]::ReadAllBytes($cogRoleFile)
    }
    $mapBeforeCombo = Get-Content -LiteralPath $livePath -Raw
    try {
        if ($cogRoleHadFile) {
            Remove-Item -LiteralPath $cogRoleFile -Force
        }
        $allDriftComboRecords = @(Get-HeadLaunchRecords -SeatMapPath $livePath)
        foreach ($row in $allDriftComboRecords) {
            if ($row.AssignedRoleId -eq $anvilRoleId) { $row.Command = $anvilDriftLaunch }
        }
        Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath -Terminals $allDriftComboRecords
        $allCombo = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-All', '-Seat', 'Anvil', '-Rung', 'then')
        $allComboCombined = "$($allCombo.StdOut)`n$($allCombo.StdErr)"
        Assert-True 'DEV-237 -All swap+syncMiss+drift: exit 1' ($allCombo.ExitCode -eq 1) '1' ("exit=$($allCombo.ExitCode)`n$allComboCombined")
        Assert-True 'DEV-237 -All swap+syncMiss+drift: Cog role miss handled' (Test-TextContains $allComboCombined 'Role file not found for Cog') 'Role file not found for Cog' $allComboCombined
        Assert-True 'DEV-237 -All swap+syncMiss+drift: VERIFY DRIFT' (Test-TextContains $allComboCombined $anvilDrift) $anvilDrift $allComboCombined
        Assert-True 'DEV-237 -All swap+syncMiss+drift: no unqualified completed receipt' (-not (Test-TextContains $allComboCombined $completedReceipt)) "absent $completedReceipt" $allComboCombined
        Assert-True 'DEV-237 -All swap+syncMiss+drift: syncMiss before verify exit' (
            ((ConvertTo-Fwd $allComboCombined).IndexOf('Role file not found for Cog') -ge 0) -and
            ((ConvertTo-Fwd $allComboCombined).IndexOf((ConvertTo-Fwd $anvilDrift)) -ge 0)
        ) 'syncMiss and drift both present' $allComboCombined
    }
    finally {
        if ($cogRoleHadFile -and $null -ne $cogRolePriorBytes) {
            [System.IO.File]::WriteAllBytes($cogRoleFile, $cogRolePriorBytes)
        }
        if ($null -ne $anvilRoleComboBytes) {
            [System.IO.File]::WriteAllBytes($anvilRoleFileForCombo, $anvilRoleComboBytes)
        }
        [System.IO.File]::WriteAllText($livePath, $mapBeforeCombo, [System.Text.UTF8Encoding]::new($false))
        Write-MatchingWorkspaceVerifyJson -WsDir $wsDir -RepoRootHint $repoRoot -SeatMapPath $livePath
    }

    $verifyComboLiteral = '-Verify cannot be combined with -Seat/-Rung because -Verify is read-only. Use -All for write/sync then verify.'
    $homeBeforeComboReject = Get-RecursiveFileSnapshot -Root $isoMaestri
    $porcelainBeforeComboReject = Get-Porcelain
    $liveHashBeforeComboReject = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash
    $verifyCombo = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify', '-Seat', 'Anvil', '-Rung', 'then')
    $verifyComboCombined = "$($verifyCombo.StdOut)`n$($verifyCombo.StdErr)"
    $homeAfterComboReject = Get-RecursiveFileSnapshot -Root $isoMaestri
    $porcelainAfterComboReject = Get-Porcelain
    $liveHashAfterComboReject = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash
    Assert-True 'DEV-237 -Verify -Seat -Rung: exit 1' ($verifyCombo.ExitCode -eq 1) '1' ("exit=$($verifyCombo.ExitCode)`n$verifyComboCombined")
    Assert-True 'DEV-237 -Verify -Seat -Rung: exact reject literal' (Test-TextContains $verifyComboCombined $verifyComboLiteral) $verifyComboLiteral $verifyComboCombined
    Assert-True 'DEV-237 -Verify -Seat -Rung: isolated HOME snapshot unchanged' ($homeBeforeComboReject -eq $homeAfterComboReject) $homeBeforeComboReject $homeAfterComboReject
    Assert-True 'DEV-237 -Verify -Seat -Rung: git porcelain unchanged' ($porcelainBeforeComboReject -eq $porcelainAfterComboReject) $porcelainBeforeComboReject $porcelainAfterComboReject
    Assert-True 'DEV-237 -Verify -Seat -Rung: seat-map hash unchanged' ($liveHashBeforeComboReject -eq $liveHashAfterComboReject) $liveHashBeforeComboReject $liveHashAfterComboReject

    # --- zero-workspace resolution failure (not A5 Init) ---
    $zeroHome = Join-Path $isoHome 'zero-ws'
    New-Item -ItemType Directory -Path (Join-Path $zeroHome '.maestri' 'workspaces') -Force | Out-Null
    $zero = Invoke-IsolatedPwsh -HomeDir $zeroHome -File $syncScript -ArgumentList @('-Validate')
    Assert-True 'zero-workspace: exit non-zero' ($zero.ExitCode -ne 0) 'non-zero' ([string]$zero.ExitCode)
    Assert-True 'zero-workspace: stderr names resolution failure' (Test-TextContains $zero.StdErr 'Seat map workspace could not be resolved:') 'Seat map workspace could not be resolved:' $zero.StdErr
    Assert-True 'zero-workspace: stderr names no-workspaces reason' (Test-TextContains $zero.StdErr 'No Maestri workspaces under') 'No Maestri workspaces under' $zero.StdErr
    Assert-True 'zero-workspace: stderr names WorkspaceId remedy' (Test-TextContains $zero.StdErr '-WorkspaceId') '-WorkspaceId' $zero.StdErr
    Assert-True 'zero-workspace: stderr names SeatMapPath remedy' (Test-TextContains $zero.StdErr '-SeatMapPath') '-SeatMapPath' $zero.StdErr
    Assert-True 'zero-workspace: stderr omits Init' (-not (Test-TextContains $zero.StdErr 'Init')) 'no Init' $zero.StdErr
    Assert-True 'zero-workspace: no bind-time throw' (-not (Test-BindTimeThrow $zero.StdOut $zero.StdErr)) 'no ParameterBindingException' "$($zero.StdOut)$($zero.StdErr)"
    $zeroVerify = Invoke-IsolatedPwsh -HomeDir $zeroHome -File $syncScript -ArgumentList @('-Verify')
    Assert-True 'zero-workspace -Verify: exit 1' ($zeroVerify.ExitCode -eq 1) '1' ([string]$zeroVerify.ExitCode)
    Assert-True 'zero-workspace -Verify: stderr names resolution failure' (Test-TextContains $zeroVerify.StdErr 'Seat map workspace could not be resolved:') 'Seat map workspace could not be resolved:' $zeroVerify.StdErr
    Assert-True 'zero-workspace -Verify: stderr names WorkspaceId remedy' (Test-TextContains $zeroVerify.StdErr '-WorkspaceId') '-WorkspaceId' $zeroVerify.StdErr
    Assert-True 'zero-workspace -Verify: stderr names SeatMapPath remedy' (Test-TextContains $zeroVerify.StdErr '-SeatMapPath') '-SeatMapPath' $zeroVerify.StdErr
    Assert-True 'zero-workspace -Verify: no bind-time throw' (-not (Test-BindTimeThrow $zeroVerify.StdOut $zeroVerify.StdErr)) 'no ParameterBindingException' "$($zeroVerify.StdOut)$($zeroVerify.StdErr)"

    # --- two-workspace (both match) resolution failure (not A5 Init) ---
    $twoHome = Join-Path $isoHome 'two-ws'
    $twoA = New-WorkspaceDir -HomeDir $twoHome -WorkspaceId ([guid]::NewGuid().ToString()) -RepoRootHint $repoRoot
    $twoB = New-WorkspaceDir -HomeDir $twoHome -WorkspaceId ([guid]::NewGuid().ToString()) -RepoRootHint $repoRoot
    $null = $twoA; $null = $twoB
    $two = Invoke-IsolatedPwsh -HomeDir $twoHome -File $syncScript -ArgumentList @('-Validate')
    Assert-True 'two-workspace: exit non-zero' ($two.ExitCode -ne 0) 'non-zero' ([string]$two.ExitCode)
    Assert-True 'two-workspace: stderr names resolution failure' (Test-TextContains $two.StdErr 'Seat map workspace could not be resolved:') 'Seat map workspace could not be resolved:' $two.StdErr
    Assert-True 'two-workspace: stderr names multiple-workspaces reason' (Test-TextContains $two.StdErr 'Multiple Maestri workspaces match this repo') 'Multiple Maestri workspaces match this repo' $two.StdErr
    Assert-True 'two-workspace: stderr names WorkspaceId remedy' (Test-TextContains $two.StdErr '-WorkspaceId') '-WorkspaceId' $two.StdErr
    Assert-True 'two-workspace: stderr names SeatMapPath remedy' (Test-TextContains $two.StdErr '-SeatMapPath') '-SeatMapPath' $two.StdErr
    Assert-True 'two-workspace: stderr omits Init' (-not (Test-TextContains $two.StdErr 'Init')) 'no Init' $two.StdErr
    Assert-True 'two-workspace: no bind-time throw' (-not (Test-BindTimeThrow $two.StdOut $two.StdErr)) 'no ParameterBindingException' "$($two.StdOut)$($two.StdErr)"
    $twoVerify = Invoke-IsolatedPwsh -HomeDir $twoHome -File $syncScript -ArgumentList @('-Verify')
    Assert-True 'two-workspace -Verify: exit 1' ($twoVerify.ExitCode -eq 1) '1' ([string]$twoVerify.ExitCode)
    Assert-True 'two-workspace -Verify: stderr names resolution failure' (Test-TextContains $twoVerify.StdErr 'Seat map workspace could not be resolved:') 'Seat map workspace could not be resolved:' $twoVerify.StdErr
    Assert-True 'two-workspace -Verify: stderr names WorkspaceId remedy' (Test-TextContains $twoVerify.StdErr '-WorkspaceId') '-WorkspaceId' $twoVerify.StdErr
    Assert-True 'two-workspace -Verify: stderr names SeatMapPath remedy' (Test-TextContains $twoVerify.StdErr '-SeatMapPath') '-SeatMapPath' $twoVerify.StdErr
    Assert-True 'two-workspace -Verify: no bind-time throw' (-not (Test-BindTimeThrow $twoVerify.StdOut $twoVerify.StdErr)) 'no ParameterBindingException' "$($twoVerify.StdOut)$($twoVerify.StdErr)"

    # --- repo-root-mismatch: one workspace whose hint names a different repo ---
    $mismatchHome = Join-Path $isoHome 'mismatch-ws'
    $mismatchWs = New-WorkspaceDir -HomeDir $mismatchHome -WorkspaceId ([guid]::NewGuid().ToString()) -RepoRootHint 'F:/Dev/not-this-harness-repo'
    $null = $mismatchWs
    $mismatch = Invoke-IsolatedPwsh -HomeDir $mismatchHome -File $syncScript -ArgumentList @('-Validate')
    Assert-True 'repo-root-mismatch: exit non-zero' ($mismatch.ExitCode -ne 0) 'non-zero' ([string]$mismatch.ExitCode)
    Assert-True 'repo-root-mismatch: stderr names resolution failure' (Test-TextContains $mismatch.StdErr 'Seat map workspace could not be resolved:') 'Seat map workspace could not be resolved:' $mismatch.StdErr
    Assert-True 'repo-root-mismatch: stderr names mismatch reason' (Test-TextContains $mismatch.StdErr 'Repo-root hint matched no Maestri workspace') 'Repo-root hint matched no Maestri workspace' $mismatch.StdErr
    Assert-True 'repo-root-mismatch: stderr names WorkspaceId remedy' (Test-TextContains $mismatch.StdErr '-WorkspaceId') '-WorkspaceId' $mismatch.StdErr
    Assert-True 'repo-root-mismatch: stderr names SeatMapPath remedy' (Test-TextContains $mismatch.StdErr '-SeatMapPath') '-SeatMapPath' $mismatch.StdErr
    Assert-True 'repo-root-mismatch: stderr omits Init' (-not (Test-TextContains $mismatch.StdErr 'Init')) 'no Init' $mismatch.StdErr
    Assert-True 'repo-root-mismatch: no bind-time throw' (-not (Test-BindTimeThrow $mismatch.StdOut $mismatch.StdErr)) 'no ParameterBindingException' "$($mismatch.StdOut)$($mismatch.StdErr)"
    $mismatchVerify = Invoke-IsolatedPwsh -HomeDir $mismatchHome -File $syncScript -ArgumentList @('-Verify')
    Assert-True 'repo-root-mismatch -Verify: exit 1' ($mismatchVerify.ExitCode -eq 1) '1' ([string]$mismatchVerify.ExitCode)
    Assert-True 'repo-root-mismatch -Verify: stderr names resolution failure' (Test-TextContains $mismatchVerify.StdErr 'Seat map workspace could not be resolved:') 'Seat map workspace could not be resolved:' $mismatchVerify.StdErr
    Assert-True 'repo-root-mismatch -Verify: stderr names WorkspaceId remedy' (Test-TextContains $mismatchVerify.StdErr '-WorkspaceId') '-WorkspaceId' $mismatchVerify.StdErr
    Assert-True 'repo-root-mismatch -Verify: stderr names SeatMapPath remedy' (Test-TextContains $mismatchVerify.StdErr '-SeatMapPath') '-SeatMapPath' $mismatchVerify.StdErr
    Assert-True 'repo-root-mismatch -Verify: no bind-time throw' (-not (Test-BindTimeThrow $mismatchVerify.StdOut $mismatchVerify.StdErr)) 'no ParameterBindingException' "$($mismatchVerify.StdOut)$($mismatchVerify.StdErr)"

    # --- swap-log workspaceId (isolated HOME; helper write) ---
    $swapWriter = Join-Path $isoHome 'write-swap.ps1'
    $helperLiteral = $helperPath.Replace("'", "''")
    $swapWriterBody = @(
        ". '$helperLiteral'"
        "Write-SeatMapSwapLog -Seat 'Anvil' -Rung 'head' -Launch 'x' -Pool 'CURSOR' -WorkspaceId '$wsId' -LiveSwapped `$false -Detail 'live-test'"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($swapWriter, $swapWriterBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $swapWrite = Invoke-IsolatedPwsh -HomeDir $isoHome -File $swapWriter
    Assert-True 'swap-log write: exit 0' ($swapWrite.ExitCode -eq 0) '0' ([string]$swapWrite.ExitCode)
    $swapLogPath = Join-Path $isoHome '.maestri' 'seat-map-swaps.jsonl'
    Assert-True 'swap-log: file created under isolated HOME' (Test-Path -LiteralPath $swapLogPath) $swapLogPath 'missing'
    $swapLine = (Get-Content -LiteralPath $swapLogPath -Raw)
    Assert-True 'swap-log: entry contains workspaceId' (Test-TextContains $swapLine $wsId) $wsId $swapLine

    # --- DEV-235 B5 & R1 A4: non-WhatIf no-billing probe write & field readback ---
    Copy-Item -LiteralPath $examplePath -Destination $livePath -Force
    [void](Install-RoleFixtures -RepoRoot $repoRoot -ExamplePath $examplePath)
    $probeFakeWriter = Join-Path $isoHome 'probe-fake-write.ps1'
    $probeScriptLiteral = $probeScript.Replace("'", "''")
    $livePathLiteral = $livePath.Replace("'", "''")
    $probeFakeBody = @(
        "`$env:SEAT_MAP_PROBE_FAKE_LAUNCH = '1'"
        "& '$probeScriptLiteral' -Host 'gemini' -Model 'gemini-3.5-flash-lite' -Test 'Verdict' -Seat 'conductor' -Rung 'alt' -SeatMapPath '$livePathLiteral'"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($probeFakeWriter, $probeFakeBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $probeFakeRes = Invoke-IsolatedPwsh -HomeDir $isoHome -File $probeFakeWriter
    Assert-True 'non-WhatIf probe fake write: exit 0' ($probeFakeRes.ExitCode -eq 0) '0' ("exit=$($probeFakeRes.ExitCode)`n$($probeFakeRes.StdOut)`n$($probeFakeRes.StdErr)")
    $writtenMap = Get-Content -LiteralPath $livePath -Raw | ConvertFrom-Json
    $condSeat = @($writtenMap.seats | Where-Object { $_.id -eq 'conductor' })[0]
    Assert-True 'non-WhatIf probe fake write: activeRung unchanged (real write contract)' ($condSeat.activeRung -eq 'head') 'head' ([string]$condSeat.activeRung)
    $altCell = @($condSeat.rungs | Where-Object { $_.name -eq 'alt' })[0]
    Assert-True 'fake probe cell readback: host' ([string]$altCell.host -eq 'gemini') 'gemini' ([string]$altCell.host)
    Assert-True 'fake probe cell readback: model' ([string]$altCell.model -eq 'gemini-3.5-flash-lite') 'gemini-3.5-flash-lite' ([string]$altCell.model)
    Assert-True 'fake probe cell readback: pool' ([string]$altCell.pool -eq 'GEMINI') 'GEMINI' ([string]$altCell.pool)
    Assert-True 'fake probe cell readback: evidence' ([string]$altCell.evidence -eq 'probed') 'probed' ([string]$altCell.evidence)
    Assert-True 'fake probe cell readback: cost.source' ([string]$altCell.cost.source -eq 'unknown') 'unknown' ([string]$altCell.cost.source)

    # --- R1 A1 & A2: Consumer fail-closed tests (schemaVersion 1 & 2.5) ---
    $v1MapPath = Join-Path $isoHome 'v1-seat-map.json'
    $v1MapContent = @'
{
    "schemaVersion": 1,
    "seats": [
        {
            "id": "conductor",
            "name": "Conductor",
            "codename": "Dudamel",
            "roleId": "0FD7CF98-CCD8-44DF-B78A-957262622A27",
            "activeRung": "head",
            "preset": "opencode",
            "head": { "launch": "codex", "pool": "CODEX", "evidence": "unmeasured", "host": "codex", "model": "gpt-5.6-luna", "tier": 3 },
            "then": { "launch": "gemini", "pool": "GEMINI", "evidence": "cleared", "host": "gemini", "model": "gemini-3.5-flash-lite", "tier": 4 },
            "floor": { "launch": "agent", "pool": "CURSOR", "evidence": "unmeasured", "host": "cursor", "model": "composer-2.5", "tier": 3 }
        }
    ]
}
'@
    [System.IO.File]::WriteAllText($v1MapPath, $v1MapContent, [System.Text.UTF8Encoding]::new($false))
    $v1Diagnostic = "Seat map schemaVersion 1 is not supported; schemaVersion 2 is required. In-place migration is not implemented."

    $v1Verify = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-Verify', '-SeatMapPath', $v1MapPath)
    $v1VerifyCombined = "$($v1Verify.StdOut)`n$($v1Verify.StdErr)"
    Assert-True 'DEV-237 invalid schema before verify: exit 1' ($v1Verify.ExitCode -eq 1) '1' ("exit=$($v1Verify.ExitCode)`n$v1VerifyCombined")
    Assert-True 'DEV-237 invalid schema before verify: diagnostic' (Test-TextContains $v1VerifyCombined $v1Diagnostic) $v1Diagnostic $v1VerifyCombined
    Assert-True 'DEV-237 invalid schema before verify: no MATCH' (-not (Test-TextContains $v1VerifyCombined '[VERIFY MATCH]')) 'no [VERIFY MATCH]' $v1VerifyCombined
    Assert-True 'DEV-237 invalid schema before verify: no DRIFT' (-not (Test-TextContains $v1VerifyCombined '[VERIFY DRIFT]')) 'no [VERIFY DRIFT]' $v1VerifyCombined
    Assert-True 'DEV-237 invalid schema before verify: no VERIFY OK' (-not (Test-TextContains $v1VerifyCombined 'VERIFY OK:')) 'no VERIFY OK:' $v1VerifyCombined

    $v1Server = Invoke-IsolatedPwsh -HomeDir $isoHome -File $serverScript -ArgumentList @('-SeatMapPath', $v1MapPath, '-Port', '8790') -TimeoutMs 15000
    Assert-True 'R1 A1 Start-SeatMapServer v1: exit 1' ($v1Server.ExitCode -eq 1) '1' ([string]$v1Server.ExitCode)
    Assert-True 'R1 A1 Start-SeatMapServer v1: exact diagnostic' (Test-TextContains "$($v1Server.StdOut)`n$($v1Server.StdErr)" $v1Diagnostic) $v1Diagnostic "$($v1Server.StdOut)`n$($v1Server.StdErr)"

    $v1Probe = Invoke-IsolatedPwsh -HomeDir $isoHome -File $probeScript -ArgumentList @('-Host', 'gemini', '-Model', 'gemini-3.5-flash-lite', '-Test', 'Verdict', '-Seat', 'conductor', '-Rung', 'alt', '-SeatMapPath', $v1MapPath, '-WhatIf')
    Assert-True 'R1 A1 Test-ModelProbe v1: exit 1' ($v1Probe.ExitCode -eq 1) '1' ([string]$v1Probe.ExitCode)
    Assert-True 'R1 A1 Test-ModelProbe v1: exact diagnostic' (Test-TextContains "$($v1Probe.StdOut)`n$($v1Probe.StdErr)" $v1Diagnostic) $v1Diagnostic "$($v1Probe.StdOut)`n$($v1Probe.StdErr)"

    $v25MapPath = Join-Path $isoHome 'v25-seat-map.json'
    $v25MapContent = (Get-Content -LiteralPath $examplePath -Raw).Replace('"schemaVersion":  2,', '"schemaVersion": 2.5,')
    [System.IO.File]::WriteAllText($v25MapPath, $v25MapContent, [System.Text.UTF8Encoding]::new($false))
    $v25Diagnostic = "Seat map schemaVersion must be the integer 2 (got 2.5); schemaVersion 1 maps fail closed and in-place migration is not implemented."

    $v25Server = Invoke-IsolatedPwsh -HomeDir $isoHome -File $serverScript -ArgumentList @('-SeatMapPath', $v25MapPath, '-Port', '8791') -TimeoutMs 15000
    Assert-True 'R1 A2 Start-SeatMapServer v2.5: exit 1' ($v25Server.ExitCode -eq 1) '1' ([string]$v25Server.ExitCode)
    Assert-True 'R1 A2 Start-SeatMapServer v2.5: exact diagnostic' (Test-TextContains "$($v25Server.StdOut)`n$($v25Server.StdErr)" $v25Diagnostic) $v25Diagnostic "$($v25Server.StdOut)`n$($v25Server.StdErr)"

    $v25Probe = Invoke-IsolatedPwsh -HomeDir $isoHome -File $probeScript -ArgumentList @('-Host', 'gemini', '-Model', 'gemini-3.5-flash-lite', '-Test', 'Verdict', '-Seat', 'conductor', '-Rung', 'alt', '-SeatMapPath', $v25MapPath, '-WhatIf')
    Assert-True 'R1 A2 Test-ModelProbe v2.5: exit 1' ($v25Probe.ExitCode -eq 1) '1' ([string]$v25Probe.ExitCode)
    Assert-True 'R1 A2 Test-ModelProbe v2.5: exact diagnostic' (Test-TextContains "$($v25Probe.StdOut)`n$($v25Probe.StdErr)" $v25Diagnostic) $v25Diagnostic "$($v25Probe.StdOut)`n$($v25Probe.StdErr)"

    # --- R1 A3: Injected quoting fixture test ---
    $quoteMapPath = Join-Path $isoHome 'quote-seat-map.json'
    $quoteMapObj = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json
    $quoteSeat = $quoteMapObj.seats[0]
    $quoteSeat.id = 'quote-seat'
    $quoteSeat.codename = 'Quote"Seat'
    $quoteSeat.preset = 'pre`set&whoami'
    $quoteSeat.activeRung = 'alt'
    $quoteSeat.rungs[2].launch = 'pwsh -NoProfile -Command "Write-Output ''hi''; $x=1; Write-Output $x"'
    $quoteMapJson = $quoteMapObj | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($quoteMapPath, $quoteMapJson, [System.Text.UTF8Encoding]::new($false))
    $expectedRecruitCmd = Get-SeatMapRecruitCommand -Codename $quoteSeat.codename -Preset $quoteSeat.preset -Launch $quoteSeat.rungs[2].launch
    $expectedRecruitPath = Join-Path $isoHome 'expected-recruit.txt'
    [System.IO.File]::WriteAllText($expectedRecruitPath, $expectedRecruitCmd, [System.Text.UTF8Encoding]::new($false))

    $syncQuote = Invoke-IsolatedPwsh -HomeDir $isoHome -File $syncScript -ArgumentList @('-SeatMapPath', $quoteMapPath, '-GenerateCommands')
    Assert-True 'R1 A3 Sync-SeatMap -GenerateCommands quoting: exit 0' ($syncQuote.ExitCode -eq 0) '0' ([string]$syncQuote.ExitCode)
    Assert-True 'R1 A3 Sync-SeatMap -GenerateCommands quoting: exact command' (Test-TextContains $syncQuote.StdOut $expectedRecruitCmd) $expectedRecruitCmd $syncQuote.StdOut

    $portalQuoteScript = Join-Path $isoHome 'test-portal-quote.ps1'
    $quoteMapPathLiteral = $quoteMapPath.Replace("'", "''")
    $serverScriptLiteral = $serverScript.Replace("'", "''")
    $portalQuoteScriptBody = @(
        "`$serverArgs = @('-NoProfile', '-File', '$serverScriptLiteral', '-Port', '8792', '-SeatMapPath', '$quoteMapPathLiteral')"
        "`$startParams = @{ FilePath = 'pwsh'; ArgumentList = `$serverArgs; PassThru = `$true; RedirectStandardOutput = (Join-Path '$isoHome' 'server-quote.log') }"
        "if (`$IsWindows) { `$startParams.WindowStyle = 'Hidden' }"
        "`$serverProc = Start-Process @startParams"
        "if (`$null -eq `$serverProc) { throw 'seat-map server failed to start' }"
        "Start-Sleep -Seconds 2"
        "try {"
        "    `$resp = Invoke-WebRequest -Uri 'http://localhost:8792/' -UseBasicParsing"
        "    if (`$resp.StatusCode -ne 200) { throw 'GET failed' }"
        "    `$html = `$resp.Content"
        "    `$tokenMatch = [regex]::Match(`$html, '<meta name=""seat-map-token"" content=""([^""]+)""')"
        "    if (-not `$tokenMatch.Success) { throw 'Token missing' }"
        "    `$token = `$tokenMatch.Groups[1].Value"
        "    `$body = @{ seatId = 'quote-seat'; rung = 'alt' } | ConvertTo-Json"
        "    `$headers = @{ 'X-Seat-Map-Token' = `$token }"
        "    `$postResp = Invoke-WebRequest -Uri 'http://localhost:8792/api/seats/set' -Method POST -Headers `$headers -Body `$body -ContentType 'application/json' -UseBasicParsing"
        "    if (`$postResp.StatusCode -ne 200) { throw 'POST failed' }"
        "    `$postJson = `$postResp.Content | ConvertFrom-Json"
        "    `$expected = [System.IO.File]::ReadAllText((Join-Path '$isoHome' 'expected-recruit.txt'))"
        "    if (`$postJson.recruitCommand -ne `$expected) { throw ""recruitCommand mismatch: got `$(`$postJson.recruitCommand)"" }"
        "} finally {"
        "    if (`$null -ne `$serverProc) { Stop-Process -Id `$serverProc.Id -Force -ErrorAction SilentlyContinue }"
        "}"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($portalQuoteScript, $portalQuoteScriptBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $portalQuoteRes = Invoke-IsolatedPwsh -HomeDir $isoHome -File $portalQuoteScript
    Assert-True 'R1 A3 Start-SeatMapServer recruitCommand quoting: exit 0' ($portalQuoteRes.ExitCode -eq 0) '0' ("exit=$($portalQuoteRes.ExitCode)`n$($portalQuoteRes.StdOut)`n$($portalQuoteRes.StdErr)")

    # --- DEV-235 B4: Portal HTTP render + POST + activeRung readback ---
    # B3 fixture: conductor needs safe measured/cleared runtime-floor candidates before declared-rung POST.
    # Probe fake write above sets alt evidence to probed; restore and pin alt cleared + floor measured.
    Copy-Item -LiteralPath $examplePath -Destination $livePath -Force
    $b3PortalMap = Get-Content -LiteralPath $livePath -Raw | ConvertFrom-Json
    $b3Conductor = @($b3PortalMap.seats | Where-Object { $_.id -eq 'conductor' })[0]
    $b3AltRung = @($b3Conductor.rungs | Where-Object { $_.name -eq 'alt' })[0]
    $b3FloorRung = @($b3Conductor.rungs | Where-Object { $_.name -eq 'floor' })[0]
    $b3AltRung.evidence = 'cleared'
    $b3FloorRung.evidence = 'measured'
    $b3PortalJson = $b3PortalMap | ConvertTo-Json -Depth 12
    if (-not $b3PortalJson.EndsWith("`n")) { $b3PortalJson += "`n" }
    [System.IO.File]::WriteAllText($livePath, $b3PortalJson, [System.Text.UTF8Encoding]::new($false))
    $livePathLiteral = $livePath.Replace("'", "''")
    $b3WsIdLiteral = $wsId.Replace("'", "''")
    $portalScript = Join-Path $isoHome 'test-portal.ps1'
    $serverScriptLiteral = $serverScript.Replace("'", "''")
    $portalScriptBody = @(
        "`$serverEnv = @{ HOME = `$env:HOME; USERPROFILE = `$env:USERPROFILE }"
        "`$serverArgs = @('-NoProfile', '-File', '$serverScriptLiteral', '-Port', '8789', '-SeatMapPath', '$livePathLiteral', '-WorkspaceId', '$b3WsIdLiteral')"
        "`$startParams = @{ FilePath = 'pwsh'; ArgumentList = `$serverArgs; PassThru = `$true; Environment = `$serverEnv; RedirectStandardOutput = (Join-Path '$isoHome' 'server.log') }"
        "if (`$IsWindows) { `$startParams.WindowStyle = 'Hidden' }"
        "`$serverProc = Start-Process @startParams"
        "if (`$null -eq `$serverProc) { throw 'seat-map server failed to start' }"
        "for (`$ready = 0; `$ready -lt 50; `$ready++) {"
        "    try {"
        "        `$probe = Invoke-WebRequest -Uri 'http://localhost:8789/' -UseBasicParsing -TimeoutSec 2"
        "        if (`$probe.StatusCode -eq 200) { break }"
        "    } catch { }"
        "    Start-Sleep -Milliseconds 200"
        "}"
        "try {"
        "    `$resp = Invoke-WebRequest -Uri 'http://localhost:8789/' -UseBasicParsing"
        "    if (`$resp.StatusCode -ne 200) { throw 'GET failed' }"
        "    `$html = `$resp.Content"
        "    if (-not `$html.Contains('seat-map-token')) { throw 'HTML missing token meta' }"
        "    `$apiResp = Invoke-WebRequest -Uri 'http://localhost:8789/api/seats' -UseBasicParsing"
        "    if (`$apiResp.StatusCode -ne 200 -or -not `$apiResp.Content.Contains('alt')) { throw 'API seats missing alt' }"
        "    `$tokenMatch = [regex]::Match(`$html, '<meta name=""seat-map-token"" content=""([^""]+)""')"
        "    if (-not `$tokenMatch.Success) { throw 'Token missing' }"
        "    `$token = `$tokenMatch.Groups[1].Value"
        "    `$body = @{ seatId = 'conductor'; rung = 'alt' } | ConvertTo-Json"
        "    `$headers = @{ 'X-Seat-Map-Token' = `$token }"
        "    `$postResp = Invoke-WebRequest -Uri 'http://localhost:8789/api/seats/set' -Method POST -Headers `$headers -Body `$body -ContentType 'application/json' -UseBasicParsing"
        "    if (`$postResp.StatusCode -ne 200) { throw 'POST failed' }"
        "    `$postJson = `$postResp.Content | ConvertFrom-Json"
        "    if (-not `$postJson.success) { throw 'POST success=false' }"
        "} finally {"
        "    if (`$null -ne `$serverProc) { Stop-Process -Id `$serverProc.Id -Force -ErrorAction SilentlyContinue }"
        "}"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($portalScript, $portalScriptBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $portalRes = Invoke-IsolatedPwsh -HomeDir $isoHome -File $portalScript
    Assert-True 'portal HTTP render+POST: exit 0' ($portalRes.ExitCode -eq 0) '0' ("exit=$($portalRes.ExitCode)`n$($portalRes.StdOut)`n$($portalRes.StdErr)")
    $portalReadbackMap = Get-Content -LiteralPath $livePath -Raw | ConvertFrom-Json
    $portalCondSeat = @($portalReadbackMap.seats | Where-Object { $_.id -eq 'conductor' })[0]
    Assert-True 'portal HTTP POST: activeRung readback confirmed alt' ($portalCondSeat.activeRung -eq 'alt') 'alt' ([string]$portalCondSeat.activeRung)

    # --- TW1: Portal failure atomicity (no-capable-floor fixture) ---
    $tw1Home = Join-Path $isoHome 'tw1-portal-fail'
    $tw1WsId = [guid]::NewGuid().ToString()
    $tw1WsDir = New-WorkspaceDir -HomeDir $tw1Home -WorkspaceId $tw1WsId -RepoRootHint $repoRoot
    Write-NoteStubs -WsDir $tw1WsDir
    $tw1MapPath = Join-Path $tw1WsDir 'seat-map.json'
    Copy-Item -LiteralPath $examplePath -Destination $tw1MapPath
    $tw1MapObj = Get-Content -LiteralPath $tw1MapPath -Raw | ConvertFrom-Json
    $tw1Anvil = @($tw1MapObj.seats | Where-Object { $_.id -eq 'anvil' })[0]
    $tw1Anvil.rungs = @(
        [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 1; evidence = 'measured' },
        [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 2; evidence = 'probed' },
        [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'probed' },
        [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 3; evidence = 'probed' }
    )
    $tw1MapJson = $tw1MapObj | ConvertTo-Json -Depth 12
    if (-not $tw1MapJson.EndsWith("`n")) { $tw1MapJson += "`n" }
    [System.IO.File]::WriteAllText($tw1MapPath, $tw1MapJson, [System.Text.UTF8Encoding]::new($false))
    $tw1AnvilRoleDir = Join-Path $repoRoot '.maestri' 'roles' 'BA23D857-A79B-4128-B154-8D05C3D5DC31'
    New-Item -ItemType Directory -Path $tw1AnvilRoleDir -Force | Out-Null
    $tw1AnvilRoleFile = Join-Path $tw1AnvilRoleDir 'role.json'
    [System.IO.File]::WriteAllText($tw1AnvilRoleFile, '{"prompt":"Model chain (best first): HEADCMD -> THENCMD -> FLOORCMD (FLOOR)."}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $tw1MapHashBefore = (Get-FileHash -LiteralPath $tw1MapPath -Algorithm SHA256).Hash
    $tw1RoleTextBefore = [System.IO.File]::ReadAllText($tw1AnvilRoleFile)
    $tw1CharterPath = Join-Path $tw1WsDir 'notes' 'harness-team-charter.md'
    $tw1RestartPath = Join-Path $tw1WsDir 'notes' 'team-restart.md'
    $tw1CharterBefore = [System.IO.File]::ReadAllText($tw1CharterPath)
    $tw1RestartBefore = [System.IO.File]::ReadAllText($tw1RestartPath)
    $tw1SwapLogPath = Join-Path $tw1Home '.maestri' 'seat-map-swaps.jsonl'
    $tw1SwapExisted = Test-Path -LiteralPath $tw1SwapLogPath
    $tw1SwapLenBefore = 0
    $tw1SwapWriteBefore = $null
    if ($tw1SwapExisted) {
        $tw1SwapItem = Get-Item -LiteralPath $tw1SwapLogPath
        $tw1SwapLenBefore = $tw1SwapItem.Length
        $tw1SwapWriteBefore = $tw1SwapItem.LastWriteTimeUtc
    }
    $tw1MapPathLiteral = $tw1MapPath.Replace("'", "''")
    $tw1PortalFailScript = Join-Path $isoHome 'test-portal-fail.ps1'
    $tw1PortalFailBody = @(
        "`$serverArgs = @('-NoProfile', '-File', '$serverScriptLiteral', '-Port', '8793', '-SeatMapPath', '$tw1MapPathLiteral')"
        "`$startParams = @{ FilePath = 'pwsh'; ArgumentList = `$serverArgs; PassThru = `$true; RedirectStandardOutput = (Join-Path '$isoHome' 'server-tw1.log') }"
        "if (`$IsWindows) { `$startParams.WindowStyle = 'Hidden' }"
        "`$serverProc = Start-Process @startParams"
        "if (`$null -eq `$serverProc) { throw 'seat-map server failed to start' }"
        "Start-Sleep -Seconds 2"
        "try {"
        "    `$resp = Invoke-WebRequest -Uri 'http://localhost:8793/' -UseBasicParsing"
        "    `$tokenMatch = [regex]::Match(`$resp.Content, '<meta name=""seat-map-token"" content=""([^""]+)""')"
        "    if (-not `$tokenMatch.Success) { throw 'Token missing' }"
        "    `$token = `$tokenMatch.Groups[1].Value"
        "    `$body = @{ seatId = 'anvil'; rung = 'then' } | ConvertTo-Json"
        "    `$headers = @{ 'X-Seat-Map-Token' = `$token }"
        "    `$postResp = Invoke-WebRequest -Uri 'http://localhost:8793/api/seats/set' -Method POST -Headers `$headers -Body `$body -ContentType 'application/json' -UseBasicParsing -SkipHttpErrorCheck"
        "    if (`$postResp.StatusCode -eq 200) { throw 'POST should fail' }"
        "    if (-not `$postResp.Content.Contains('Seat ''Anvil'' has no capable runtime floor')) { throw 'missing capable-floor error' }"
        "} finally {"
        "    if (`$null -ne `$serverProc) { Stop-Process -Id `$serverProc.Id -Force -ErrorAction SilentlyContinue }"
        "}"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($tw1PortalFailScript, $tw1PortalFailBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $tw1PortalFailRes = Invoke-IsolatedPwsh -HomeDir $tw1Home -File $tw1PortalFailScript
    Assert-True 'TW1 portal failure POST: exit 0' ($tw1PortalFailRes.ExitCode -eq 0) '0' ("exit=$($tw1PortalFailRes.ExitCode)`n$($tw1PortalFailRes.StdOut)`n$($tw1PortalFailRes.StdErr)")
    $tw1MapHashAfter = (Get-FileHash -LiteralPath $tw1MapPath -Algorithm SHA256).Hash
    Assert-True 'TW1 portal failure: seat-map hash unchanged' ($tw1MapHashBefore -eq $tw1MapHashAfter) $tw1MapHashBefore $tw1MapHashAfter
    $tw1RoleTextAfter = [System.IO.File]::ReadAllText($tw1AnvilRoleFile)
    Assert-True 'TW1 portal failure: role file text unchanged' ($tw1RoleTextBefore -eq $tw1RoleTextAfter) 'unchanged' 'changed'
    $tw1CharterAfter = [System.IO.File]::ReadAllText($tw1CharterPath)
    Assert-True 'TW1 portal failure: harness-team-charter text unchanged' ($tw1CharterBefore -eq $tw1CharterAfter) 'unchanged' 'changed'
    $tw1RestartAfter = [System.IO.File]::ReadAllText($tw1RestartPath)
    Assert-True 'TW1 portal failure: team-restart text unchanged' ($tw1RestartBefore -eq $tw1RestartAfter) 'unchanged' 'changed'
    if ($tw1SwapExisted) {
        $tw1SwapItemAfter = Get-Item -LiteralPath $tw1SwapLogPath
        Assert-True 'TW1 portal failure: swap-log mtime unchanged' ($tw1SwapItemAfter.LastWriteTimeUtc -eq $tw1SwapWriteBefore) ([string]$tw1SwapWriteBefore) ([string]$tw1SwapItemAfter.LastWriteTimeUtc)
        Assert-True 'TW1 portal failure: swap-log length unchanged' ($tw1SwapItemAfter.Length -eq $tw1SwapLenBefore) ([string]$tw1SwapLenBefore) ([string]$tw1SwapItemAfter.Length)
    }
    else {
        Assert-True 'TW1 portal failure: swap-log not created' (-not (Test-Path -LiteralPath $tw1SwapLogPath)) 'absent' ([string](Test-Path -LiteralPath $tw1SwapLogPath))
    }

    # --- DEV-236: Pre-flight validations (Junie, OpenCode, Cursor) ---
    $preflightHome = Join-Path $isoHome 'preflight-home'
    New-Item -ItemType Directory -Path $preflightHome -Force | Out-Null
    $junieDir = Join-Path $preflightHome '.junie'
    New-Item -ItemType Directory -Path $junieDir -Force | Out-Null
    $junieFile = Join-Path $junieDir 'settings.json'

    # Junie 1: Missing settings file -> exit 1, sanitized stderr
    $resJ1 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'junie', '-Model', 'gpt-4o', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Junie missing settings: exit 1' ($resJ1.ExitCode -eq 1) '1' ([string]$resJ1.ExitCode)
    Assert-True 'DEV-236 Junie missing settings: sanitized stderr' (Test-TextContains $resJ1.StdErr 'Junie pre-flight failed: settings file missing:') 'missing' $resJ1.StdErr

    # Junie 2: Invalid JSON -> exit 1, sanitized stderr
    [System.IO.File]::WriteAllText($junieFile, '{ invalid json', [System.Text.UTF8Encoding]::new($false))
    $resJ2 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'junie', '-Model', 'gpt-4o', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Junie invalid JSON: exit 1' ($resJ2.ExitCode -eq 1) '1' ([string]$resJ2.ExitCode)
    Assert-True 'DEV-236 Junie invalid JSON: sanitized stderr' (Test-TextContains $resJ2.StdErr 'Junie pre-flight failed: settings file is not valid JSON:') 'not valid JSON' $resJ2.StdErr
    Assert-True 'DEV-236 Junie invalid JSON: stderr conceals raw file content' (-not (Test-TextContains $resJ2.StdErr '{ invalid json')) 'concealed' $resJ2.StdErr

    # Junie 3: Missing effortPerModel -> exit 1, sanitized stderr
    [System.IO.File]::WriteAllText($junieFile, '{"other": 123}', [System.Text.UTF8Encoding]::new($false))
    $resJ3 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'junie', '-Model', 'gpt-4o', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Junie missing effortPerModel: exit 1' ($resJ3.ExitCode -eq 1) '1' ([string]$resJ3.ExitCode)
    Assert-True 'DEV-236 Junie missing effortPerModel: sanitized stderr' (Test-TextContains $resJ3.StdErr 'Junie pre-flight failed: effortPerModel missing:') 'missing' $resJ3.StdErr

    # Junie 4: Non-object effortPerModel -> exit 1, sanitized stderr
    [System.IO.File]::WriteAllText($junieFile, '{"effortPerModel": "high"}', [System.Text.UTF8Encoding]::new($false))
    $resJ4 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'junie', '-Model', 'gpt-4o', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Junie non-object effortPerModel: exit 1' ($resJ4.ExitCode -eq 1) '1' ([string]$resJ4.ExitCode)
    Assert-True 'DEV-236 Junie non-object effortPerModel: sanitized stderr' (Test-TextContains $resJ4.StdErr 'Junie pre-flight failed: effortPerModel is not an object:') 'not an object' $resJ4.StdErr

    # Junie 5: Valid settings under -WhatIf -> exit 0, file byte-identical
    $validJunieContent = '{"effortPerModel": {"gpt-4o": "medium"}}' + [Environment]::NewLine
    [System.IO.File]::WriteAllText($junieFile, $validJunieContent, [System.Text.UTF8Encoding]::new($false))
    $resJ5 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'junie', '-Model', 'gpt-4o', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Junie valid -WhatIf: exit 0' ($resJ5.ExitCode -eq 0) '0' ([string]$resJ5.ExitCode)
    $afterJunieContent = [System.IO.File]::ReadAllText($junieFile)
    Assert-True 'DEV-236 Junie valid -WhatIf: file byte-identical' ($afterJunieContent -eq $validJunieContent) 'byte-identical' $afterJunieContent

    # Junie 6: Restore fidelity seam (Write-JunieEffortOnly & Restore-JunieEffort helper test)
    # R1-B: Source-equality hash guard proving inline seam copies match Test-ModelProbe.ps1 production helpers
    $probeScriptContent = Get-Content -LiteralPath $probeScript -Raw
    $extractHelper = {
        param([string]$FuncName, [string]$Content)
        $match = [regex]::Match($Content, "(?s)function\s+$FuncName\s*\{.*?\n\}")
        if (-not $match.Success) { throw "Helper $FuncName not found in Test-ModelProbe.ps1" }
        return $match.Value.Trim()
    }
    $prodRead = &$extractHelper 'Read-JunieEffortOnly' $probeScriptContent
    $prodWrite = &$extractHelper 'Write-JunieEffortOnly' $probeScriptContent
    $prodRestore = &$extractHelper 'Restore-JunieEffort' $probeScriptContent
    Assert-True 'DEV-236 Junie restore seam source equality: Read-JunieEffortOnly present' ([string]::IsNullOrWhiteSpace($prodRead) -eq $false) 'present' 'empty'
    Assert-True 'DEV-236 Junie restore seam source equality: Write-JunieEffortOnly present' ([string]::IsNullOrWhiteSpace($prodWrite) -eq $false) 'present' 'empty'
    Assert-True 'DEV-236 Junie restore seam source equality: Restore-JunieEffort present' ([string]::IsNullOrWhiteSpace($prodRestore) -eq $false) 'present' 'empty'

    $seamScript = Join-Path $isoHome 'junie-seam-test.ps1'
    $helperPathLiteral = $helperPath.Replace("'", "''")
    $seamScriptBody = @(
        ". '$helperPathLiteral'"
        $prodRead
        $prodWrite
        $prodRestore
        "`$backup = Read-JunieEffortOnly -SettingsPath '$($junieFile.Replace("'", "''"))' -ModelName 'gpt-4o'"
        "Write-JunieEffortOnly -SettingsPath '$($junieFile.Replace("'", "''"))' -ModelName 'gpt-4o' -Effort 'high'"
        "Restore-JunieEffort -Backup `$backup -SettingsPath '$($junieFile.Replace("'", "''"))' -ModelName 'gpt-4o'"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($seamScript, $seamScriptBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $resJ6 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $seamScript
    Assert-True 'DEV-236 Junie restore fidelity seam: exit 0' ($resJ6.ExitCode -eq 0) '0' ([string]$resJ6.ExitCode)
    $restoredJunieContent = [System.IO.File]::ReadAllText($junieFile)
    $restoredObj = $restoredJunieContent | ConvertFrom-Json
    $expectedObj = $validJunieContent | ConvertFrom-Json
    Assert-True 'DEV-236 Junie restore fidelity seam: restored content match' ($restoredObj.effortPerModel.'gpt-4o' -eq $expectedObj.effortPerModel.'gpt-4o') 'restored' $restoredJunieContent

    # Junie 7: R1-D Portable Unreadable Settings Leg
    if (Test-Path -LiteralPath $junieFile) { Remove-Item -LiteralPath $junieFile -Recurse -Force }
    New-Item -ItemType Directory -Path $junieFile -Force | Out-Null
    $resJUnreadable = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'junie', '-Model', 'gpt-4o', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Junie unreadable settings: exit 1' ($resJUnreadable.ExitCode -eq 1) '1' ([string]$resJUnreadable.ExitCode)
    Assert-True 'DEV-236 Junie unreadable settings: sanitized stderr' (Test-TextContains $resJUnreadable.StdErr 'Junie pre-flight failed: settings file unreadable:') 'unreadable' $resJUnreadable.StdErr
    Assert-True 'DEV-236 Junie unreadable settings: stderr names settings path' (Test-TextContains $resJUnreadable.StdErr $junieFile) $junieFile $resJUnreadable.StdErr
    Assert-True 'DEV-236 Junie unreadable settings: stderr conceals raw file content' (-not (Test-TextContains $resJUnreadable.StdErr 'System.UnauthorizedAccessException') -and -not (Test-TextContains $resJUnreadable.StdErr 'Access to the path')) 'concealed' $resJUnreadable.StdErr
    Remove-Item -LiteralPath $junieFile -Recurse -Force

    # OpenCode 1: Configured reasoning.effort -> stdout Warning & Note, exit 0
    $opencodeDir = Join-Path (Join-Path $preflightHome '.config') 'opencode'
    New-Item -ItemType Directory -Path $opencodeDir -Force | Out-Null
    $opencodeFile = Join-Path $opencodeDir 'opencode.jsonc'
    [System.IO.File]::WriteAllText($opencodeFile, '// comment' + [Environment]::NewLine + '{"reasoning": {"effort": "high"}}', [System.Text.UTF8Encoding]::new($false))
    $resO1 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'opencode', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 OpenCode configured effort: exit 0' ($resO1.ExitCode -eq 0) '0' ([string]$resO1.ExitCode)
    Assert-True 'DEV-236 OpenCode configured effort: stdout Warning present' (Test-TextContains $resO1.StdOut 'Warning:  reasoning.effort=high is a global/shared OpenCode setting') 'Warning' $resO1.StdOut
    Assert-True 'DEV-236 OpenCode configured effort: stdout Note present' (Test-TextContains $resO1.StdOut 'Note:     OpenCode probes should not run while live OpenCode seats are active.') 'Note' $resO1.StdOut

    # OpenCode 2: Invalid config -> non-blocking under -WhatIf, exit 0, Note on stdout
    [System.IO.File]::WriteAllText($opencodeFile, '{ invalid jsonc', [System.Text.UTF8Encoding]::new($false))
    $resO2 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'opencode', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 OpenCode invalid config: non-blocking exit 0' ($resO2.ExitCode -eq 0) '0' ([string]$resO2.ExitCode)
    Assert-True 'DEV-236 OpenCode invalid config: stdout Note present' (Test-TextContains $resO2.StdOut 'Note:     OpenCode config invalid:') 'Note' $resO2.StdOut
    Assert-True 'DEV-236 OpenCode invalid config: stdout conceals raw file content' (-not (Test-TextContains $resO2.StdOut '{ invalid jsonc')) 'concealed' $resO2.StdOut

    # OpenCode 3: R1-D Portable Unreadable Config Leg
    if (Test-Path -LiteralPath $opencodeFile) { Remove-Item -LiteralPath $opencodeFile -Recurse -Force }
    New-Item -ItemType Directory -Path $opencodeFile -Force | Out-Null
    $resOUnreadable = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'opencode', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 OpenCode unreadable config: non-blocking exit 0' ($resOUnreadable.ExitCode -eq 0) '0' ([string]$resOUnreadable.ExitCode)
    Assert-True 'DEV-236 OpenCode unreadable config: stdout Note present' (Test-TextContains $resOUnreadable.StdOut 'Note:     OpenCode config unreadable:') 'Note' $resOUnreadable.StdOut
    Assert-True 'DEV-236 OpenCode unreadable config: stdout names config path' (Test-TextContains $resOUnreadable.StdOut $opencodeFile) $opencodeFile $resOUnreadable.StdOut
    Assert-True 'DEV-236 OpenCode unreadable config: stdout conceals raw file content' (-not (Test-TextContains $resOUnreadable.StdOut 'System.UnauthorizedAccessException') -and -not (Test-TextContains $resOUnreadable.StdOut 'Access to the path')) 'concealed' $resOUnreadable.StdOut
    Assert-True 'DEV-236 OpenCode unreadable config: stderr empty' ([string]::IsNullOrWhiteSpace($resOUnreadable.StdErr)) '(empty)' $resOUnreadable.StdErr
    Remove-Item -LiteralPath $opencodeFile -Recurse -Force

    # Cursor 1: Missing cli-config.json -> exit 0
    $cursorDir = Join-Path $preflightHome '.cursor'
    New-Item -ItemType Directory -Path $cursorDir -Force | Out-Null
    $cursorFile = Join-Path $cursorDir 'cli-config.json'
    if (Test-Path -LiteralPath $cursorFile) { Remove-Item -LiteralPath $cursorFile -Force }
    $resC1 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'cursor', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Cursor missing config: exit 0' ($resC1.ExitCode -eq 0) '0' ([string]$resC1.ExitCode)

    # Cursor 2: R1-C Present Valid Config With No Model Declaration
    [System.IO.File]::WriteAllText($cursorFile, '{"other": 1}', [System.Text.UTF8Encoding]::new($false))
    $resCNoModel = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'cursor', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Cursor no-model config: exit 0' ($resCNoModel.ExitCode -eq 0) '0' ([string]$resCNoModel.ExitCode)
    Assert-True 'DEV-236 Cursor no-model config: stderr empty' ([string]::IsNullOrWhiteSpace($resCNoModel.StdErr)) '(empty)' $resCNoModel.StdErr
    Assert-True 'DEV-236 Cursor no-model config: stdout WhatIf present' (Test-TextContains $resCNoModel.StdOut 'WhatIf:   validate+resolve+construct complete; launch will not execute.') 'WhatIf' $resCNoModel.StdOut

    # Cursor 3: Matching model (exact ordinal trimmed) -> exit 0
    [System.IO.File]::WriteAllText($cursorFile, '{"model": {"modelId": "  claude-3-5-sonnet  "}}', [System.Text.UTF8Encoding]::new($false))
    $resC2 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'cursor', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Cursor matching model: exit 0' ($resC2.ExitCode -eq 0) '0' ([string]$resC2.ExitCode)

    # Cursor 4: Extraction order precedence test (model.modelId beats selectedModel.modelId)
    [System.IO.File]::WriteAllText($cursorFile, '{"model": {"modelId": "claude-3-5-sonnet"}, "selectedModel": {"modelId": "gpt-4o"}}', [System.Text.UTF8Encoding]::new($false))
    $resC3 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'cursor', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Cursor extraction precedence (model.modelId): exit 0' ($resC3.ExitCode -eq 0) '0' ([string]$resC3.ExitCode)

    # Cursor 5: Conflicting model -> exit 1, sanitized stderr
    [System.IO.File]::WriteAllText($cursorFile, '{"model": "gpt-4o"}', [System.Text.UTF8Encoding]::new($false))
    $resC4 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'cursor', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Cursor conflicting model: exit 1' ($resC4.ExitCode -eq 1) '1' ([string]$resC4.ExitCode)
    Assert-True 'DEV-236 Cursor conflicting model: sanitized stderr' (Test-TextContains $resC4.StdErr 'Cursor pre-flight failed: configured model conflicts with -Model:') 'conflicts' $resC4.StdErr

    # Cursor 6: Malformed config -> fail-closed exit 1, sanitized stderr
    [System.IO.File]::WriteAllText($cursorFile, '{ bad cursor json', [System.Text.UTF8Encoding]::new($false))
    $resC5 = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'cursor', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Cursor malformed config: fail-closed exit 1' ($resC5.ExitCode -eq 1) '1' ([string]$resC5.ExitCode)
    Assert-True 'DEV-236 Cursor malformed config: sanitized stderr' (Test-TextContains $resC5.StdErr 'Cursor pre-flight failed: config file is not valid JSON:') 'not valid JSON' $resC5.StdErr
    Assert-True 'DEV-236 Cursor malformed config: stderr conceals raw file content' (-not (Test-TextContains $resC5.StdErr '{ bad cursor json')) 'concealed' $resC5.StdErr

    # Cursor 7: R1-D Portable Unreadable Config Leg
    if (Test-Path -LiteralPath $cursorFile) { Remove-Item -LiteralPath $cursorFile -Recurse -Force }
    New-Item -ItemType Directory -Path $cursorFile -Force | Out-Null
    $resCUnreadable = Invoke-IsolatedPwsh -HomeDir $preflightHome -File $probeScript -ArgumentList @('-Host', 'cursor', '-Model', 'claude-3-5-sonnet', '-Test', 'Verdict', '-WhatIf')
    Assert-True 'DEV-236 Cursor unreadable config: exit 1' ($resCUnreadable.ExitCode -eq 1) '1' ([string]$resCUnreadable.ExitCode)
    Assert-True 'DEV-236 Cursor unreadable config: sanitized stderr' (Test-TextContains $resCUnreadable.StdErr 'Cursor pre-flight failed: config file unreadable:') 'unreadable' $resCUnreadable.StdErr
    Assert-True 'DEV-236 Cursor unreadable config: stderr names config path' (Test-TextContains $resCUnreadable.StdErr $cursorFile) $cursorFile $resCUnreadable.StdErr
    Assert-True 'DEV-236 Cursor unreadable config: stderr conceals raw file content' (-not (Test-TextContains $resCUnreadable.StdErr 'System.UnauthorizedAccessException') -and -not (Test-TextContains $resCUnreadable.StdErr 'Access to the path')) 'concealed' $resCUnreadable.StdErr
    Remove-Item -LiteralPath $cursorFile -Recurse -Force



    # --- DEV-234 Runtime Floor Anchoring Isolated Tests (A1 - A12) ---
    $dev234Home = Join-Path $isoHome 'dev234-tests'
    $dev234WsId = [guid]::NewGuid().ToString()
    $dev234WsDir = New-WorkspaceDir -HomeDir $dev234Home -WorkspaceId $dev234WsId -RepoRootHint $repoRoot
    Write-NoteStubs -WsDir $dev234WsDir
    $dev234MapPath = Join-Path $dev234WsDir 'seat-map.json'

    # B2: snapshot Anvil role bytes before isolated writes; restore in finally
    $dev234AnvilRoleDir = Join-Path $repoRoot '.maestri' 'roles' 'BA23D857-A79B-4128-B154-8D05C3D5DC31'
    $dev234AnvilRoleDirExisted = Test-Path -LiteralPath $dev234AnvilRoleDir
    $dev234AnvilRoleFile = Join-Path $dev234AnvilRoleDir 'role.json'
    $dev234AnvilRoleHadFile = Test-Path -LiteralPath $dev234AnvilRoleFile
    if ($dev234AnvilRoleHadFile) {
        $dev234AnvilRolePriorBytes = [System.IO.File]::ReadAllBytes($dev234AnvilRoleFile)
    }
    New-Item -ItemType Directory -Path $dev234AnvilRoleDir -Force | Out-Null
    $anvilRoleFile = $dev234AnvilRoleFile
    $dev234InvalidTierLiteral = "Seat 'Anvil' measured/cleared rung 'floor' has invalid tier"
    $dev234NoFloorLiteral = "Seat 'Anvil' has no capable runtime floor"

    # Inline seat map mutation script block
    $mutateSeat = {
        param([string]$MapPath, [string]$SeatId, [scriptblock]$Block)
        $map = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json
        foreach ($s in @($map.seats)) {
            if ($s.id -eq $SeatId -or $s.codename -eq $SeatId) {
                & $Block $s
                break
            }
        }
        $json = $map | ConvertTo-Json -Depth 12
        if (-not $json.EndsWith("`n")) { $json += "`n" }
        [System.IO.File]::WriteAllText($MapPath, $json, [System.Text.UTF8Encoding]::new($false))
    }

    # Test A1: Lowest safe tier selection (tiers 1, 2, 4 -> anchors FLOOR to tier-1 launch)
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 4; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 1; evidence = 'measured' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'measured' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 2; evidence = 'measured' }
        )
    }
    [System.IO.File]::WriteAllText($anvilRoleFile, '{"prompt":"Model chain (best first): HEADCMD -> THENCMD -> FLOORCMD (FLOOR)."}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $swapA1 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'then', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'A1 target swap: exit 0' ($swapA1.ExitCode -eq 0) '0' ([string]$swapA1.ExitCode)
    $anvilRoleJson = Get-Content -LiteralPath $anvilRoleFile -Raw | ConvertFrom-Json
    Assert-True 'A1 model chain FLOOR uses tier-1 launch' (Test-TextContains $anvilRoleJson.prompt '-> THENCMD (FLOOR).') '-> THENCMD (FLOOR).' $anvilRoleJson.prompt

    # Test A2: Ignore ineligible evidence (probed, unmeasured, blank)
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 4; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 1; evidence = 'probed' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'measured' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 2; evidence = 'measured' }
        )
    }
    [System.IO.File]::WriteAllText($anvilRoleFile, '{"prompt":"Model chain (best first): HEADCMD -> THENCMD -> FLOORCMD (FLOOR)."}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $swapA2 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'A2 target swap: exit 0' ($swapA2.ExitCode -eq 0) '0' ([string]$swapA2.ExitCode)
    $anvilRoleJson2 = Get-Content -LiteralPath $anvilRoleFile -Raw | ConvertFrom-Json
    Assert-True 'A2 model chain FLOOR ignores probed tier 1 and uses measured tier 2' (Test-TextContains $anvilRoleJson2.prompt '-> FLOORCMD (FLOOR).') '-> FLOORCMD (FLOOR).' $anvilRoleJson2.prompt

    # TW3: Lowest-tier cleared evidence candidate selects CLEAREDCMD
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 4; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 2; evidence = 'measured' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'measured' },
            [pscustomobject]@{ name = 'cleared'; launch = 'CLEAREDCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-cleared'; tier = 1; evidence = 'cleared' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'AGY-G'; host = 'agy'; model = 'm-floor'; tier = 3; evidence = 'measured' }
        )
    }
    [System.IO.File]::WriteAllText($anvilRoleFile, '{"prompt":"Model chain (best first): HEADCMD -> THENCMD -> FLOORCMD (FLOOR)."}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $swapTw3 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'TW3 cleared evidence target swap: exit 0' ($swapTw3.ExitCode -eq 0) '0' ([string]$swapTw3.ExitCode)
    $anvilRoleJsonTw3 = Get-Content -LiteralPath $anvilRoleFile -Raw | ConvertFrom-Json
    Assert-True 'TW3 model chain FLOOR uses lowest-tier cleared launch' (Test-TextContains $anvilRoleJsonTw3.prompt '-> CLEAREDCMD (FLOOR).') '-> CLEAREDCMD (FLOOR).' $anvilRoleJsonTw3.prompt

    # Test A3: ZEN disallowed pool exclusion for non-exception seat (Anvil)
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 4; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'opencode -m m-zen'; pool = 'ZEN'; host = 'opencode'; model = 'm-zen'; tier = 1; evidence = 'measured' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'measured' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 2; evidence = 'measured' }
        )
    }
    [System.IO.File]::WriteAllText($anvilRoleFile, '{"prompt":"Model chain (best first): HEADCMD -> opencode -m m-zen -> FLOORCMD (FLOOR)."}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $swapA3 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'A3 target swap: exit 0' ($swapA3.ExitCode -eq 0) '0' ([string]$swapA3.ExitCode)
    $anvilRoleJson3 = Get-Content -LiteralPath $anvilRoleFile -Raw | ConvertFrom-Json
    Assert-True 'A3 model chain FLOOR excludes ZEN candidate and selects tier 2 GEMINI' (Test-TextContains $anvilRoleJson3.prompt '-> FLOORCMD (FLOOR).') '-> FLOORCMD (FLOOR).' $anvilRoleJson3.prompt

    # Test A4: Head-pool exclusion & tie resolution order (floor, then, head)
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 1; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 2; evidence = 'measured' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'measured' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 2; evidence = 'measured' }
        )
    }
    [System.IO.File]::WriteAllText($anvilRoleFile, '{"prompt":"Model chain (best first): HEADCMD -> THENCMD -> FLOORCMD (FLOOR)."}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $swapA4 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'A4 target swap: exit 0' ($swapA4.ExitCode -eq 0) '0' ([string]$swapA4.ExitCode)
    $anvilRoleJson4 = Get-Content -LiteralPath $anvilRoleFile -Raw | ConvertFrom-Json
    Assert-True 'A4 excludes head pool and breaks tie to floor rung' (Test-TextContains $anvilRoleJson4.prompt '-> FLOORCMD (FLOOR).') '-> FLOORCMD (FLOOR).' $anvilRoleJson4.prompt

    # TW4: Same-tier then beats head and middle/alt
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 2; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 2; evidence = 'measured' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 2; evidence = 'measured' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 4; evidence = 'probed' }
        )
    }
    [System.IO.File]::WriteAllText($anvilRoleFile, '{"prompt":"Model chain (best first): HEADCMD -> THENCMD -> FLOORCMD (FLOOR)."}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $swapTw4 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'TW4 same-tier then-vs-head target swap: exit 0' ($swapTw4.ExitCode -eq 0) '0' ([string]$swapTw4.ExitCode)
    $anvilRoleJsonTw4 = Get-Content -LiteralPath $anvilRoleFile -Raw | ConvertFrom-Json
    Assert-True 'TW4 then beats head at same tier' (Test-TextContains $anvilRoleJsonTw4.prompt '-> THENCMD (FLOOR).') '-> THENCMD (FLOOR).' $anvilRoleJsonTw4.prompt
    Assert-True 'TW4 then beats middle/alt at same tier' (Test-TextContains $anvilRoleJsonTw4.prompt '-> THENCMD (FLOOR).') '-> THENCMD (FLOOR).' $anvilRoleJsonTw4.prompt

    # TW2 / A5: Missing, blank, and non-numeric tier failures
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs[3].tier = 'invalid'
    }
    $swapA5NonNumeric = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'A5 swap with non-numeric tier fails non-zero' ($swapA5NonNumeric.ExitCode -ne 0) 'non-zero' ([string]$swapA5NonNumeric.ExitCode)
    Assert-True 'TW2 non-numeric tier names seat and floor rung' (Test-TextContains $swapA5NonNumeric.StdErr $dev234InvalidTierLiteral) $dev234InvalidTierLiteral $swapA5NonNumeric.StdErr

    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $null = $s.rungs[3].PSObject.Properties.Remove('tier')
    }
    $swapA5Missing = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'TW2 missing tier fails non-zero' ($swapA5Missing.ExitCode -ne 0) 'non-zero' ([string]$swapA5Missing.ExitCode)
    Assert-True 'TW2 missing tier names seat and floor rung' (Test-TextContains $swapA5Missing.StdErr $dev234InvalidTierLiteral) $dev234InvalidTierLiteral $swapA5Missing.StdErr

    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs[3].tier = ''
    }
    $swapA5Blank = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'head', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'TW2 blank tier fails non-zero' ($swapA5Blank.ExitCode -ne 0) 'non-zero' ([string]$swapA5Blank.ExitCode)
    Assert-True 'TW2 blank tier names seat and floor rung' (Test-TextContains $swapA5Blank.StdErr $dev234InvalidTierLiteral) $dev234InvalidTierLiteral $swapA5Blank.StdErr

    # Test A6 & A7: No safe floor failure & Pre-write atomicity
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 1; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 2; evidence = 'probed' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'probed' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 3; evidence = 'probed' }
        )
    }
    $mapHashMutated = (Get-FileHash -LiteralPath $dev234MapPath -Algorithm SHA256).Hash
    $swapA6 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'then', '-SyncRoles', '-SeatMapPath', $dev234MapPath)
    Assert-True 'A6 swap with no safe floor fails non-zero' ($swapA6.ExitCode -ne 0) 'non-zero' ([string]$swapA6.ExitCode)
    Assert-True 'A6 failure names no capable runtime floor' (Test-TextContains $swapA6.StdErr $dev234NoFloorLiteral) $dev234NoFloorLiteral $swapA6.StdErr
    $mapHashAfterFail = (Get-FileHash -LiteralPath $dev234MapPath -Algorithm SHA256).Hash
    Assert-True 'A7 seat-map file unchanged after failed target swap' ($mapHashMutated -eq $mapHashAfterFail) $mapHashMutated $mapHashAfterFail

    # Test A8: ActiveRung=floor launch consistency across active surfaces
    Copy-Item -LiteralPath $examplePath -Destination $dev234MapPath
    & $mutateSeat $dev234MapPath 'Anvil' {
        param($s)
        $s.rungs = @(
            [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADCMD'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 4; evidence = 'measured' },
            [pscustomobject]@{ name = 'then'; launch = 'THENCMD'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 1; evidence = 'measured' },
            [pscustomobject]@{ name = 'alt'; launch = 'ALTCMD'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'measured' },
            [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORCMD'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 2; evidence = 'measured' }
        )
    }
    Write-MatchingWorkspaceVerifyJson -WsDir $dev234WsDir -RepoRootHint $repoRoot -SeatMapPath $dev234MapPath
    $swapA8 = Invoke-IsolatedPwsh -HomeDir $dev234Home -File $syncScript -ArgumentList @('-Seat', 'Anvil', '-Rung', 'floor', '-All', '-SeatMapPath', $dev234MapPath)
    Assert-True 'A8 target swap on activeRung=floor exit 0' ($swapA8.ExitCode -eq 0) '0' ([string]$swapA8.ExitCode)
    Assert-True 'A8 recruit command uses resolved runtime floor launch' (Test-TextContains $swapA8.StdOut 'THENCMD') 'THENCMD' $swapA8.StdOut
    $charterTxt = Get-Content -LiteralPath (Join-Path $dev234WsDir 'notes' 'harness-team-charter.md') -Raw
    Assert-True 'A8 harness-team-charter uses resolved runtime floor launch' (Test-TextContains $charterTxt 'THENCMD') 'THENCMD' $charterTxt
    $restartTxt = Get-Content -LiteralPath (Join-Path $dev234WsDir 'notes' 'team-restart.md') -Raw
    Assert-True 'A8 team-restart uses resolved runtime floor launch' (Test-TextContains $restartTxt 'THENCMD') 'THENCMD' $restartTxt

    # TW5: Non-swap commands tolerate unrelated incapable seat
    $tw5Home = Join-Path $isoHome 'tw5-non-swap'
    $tw5WsId = [guid]::NewGuid().ToString()
    $tw5WsDir = New-WorkspaceDir -HomeDir $tw5Home -WorkspaceId $tw5WsId -RepoRootHint $repoRoot
    Write-NoteStubs -WsDir $tw5WsDir
    $tw5MapPath = Join-Path $tw5WsDir 'seat-map.json'
    Copy-Item -LiteralPath $examplePath -Destination $tw5MapPath
    $tw5MapObj = Get-Content -LiteralPath $tw5MapPath -Raw | ConvertFrom-Json
    $tw5Keel = @($tw5MapObj.seats | Where-Object { $_.id -eq 'keel' })[0]
    $tw5Keel.rungs = @(
        [pscustomobject]@{ role = 'head'; name = 'head'; launch = 'HEADK'; pool = 'CODEX'; host = 'codex'; model = 'm-head'; tier = 1; evidence = 'probed' },
        [pscustomobject]@{ name = 'then'; launch = 'THENK'; pool = 'CURSOR'; host = 'cursor'; model = 'm-then'; tier = 2; evidence = 'unmeasured' },
        [pscustomobject]@{ name = 'alt'; launch = 'ALTK'; pool = 'OPENROUTER'; host = 'cursor'; model = 'm-alt'; tier = 3; evidence = 'probed' },
        [pscustomobject]@{ role = 'floor'; name = 'floor'; launch = 'FLOORK'; pool = 'GEMINI'; host = 'gemini'; model = 'm-floor'; tier = 4; evidence = 'probed' }
    )
    $tw5MapJson = $tw5MapObj | ConvertTo-Json -Depth 12
    if (-not $tw5MapJson.EndsWith("`n")) { $tw5MapJson += "`n" }
    [System.IO.File]::WriteAllText($tw5MapPath, $tw5MapJson, [System.Text.UTF8Encoding]::new($false))
    $tw5Validate = Invoke-IsolatedPwsh -HomeDir $tw5Home -File $syncScript -ArgumentList @('-Validate', '-SeatMapPath', $tw5MapPath)
    Assert-True 'TW5 -Validate with unrelated incapable seat: exit 0' ($tw5Validate.ExitCode -eq 0) '0' ([string]$tw5Validate.ExitCode)
    Assert-True 'TW5 -Validate: no target runtime-floor error' (-not (Test-TextContains "$($tw5Validate.StdOut)`n$($tw5Validate.StdErr)" $dev234NoFloorLiteral)) "no $dev234NoFloorLiteral" "$($tw5Validate.StdOut)`n$($tw5Validate.StdErr)"
    Write-MatchingWorkspaceVerifyJson -WsDir $tw5WsDir -RepoRootHint $repoRoot -SeatMapPath $tw5MapPath
    $tw5All = Invoke-IsolatedPwsh -HomeDir $tw5Home -File $syncScript -ArgumentList @('-All', '-SeatMapPath', $tw5MapPath)
    Assert-True 'TW5 -All with unrelated incapable seat: exit 0' ($tw5All.ExitCode -eq 0) '0' ([string]$tw5All.ExitCode)
    Assert-True 'TW5 -All: no target runtime-floor error' (-not (Test-TextContains "$($tw5All.StdOut)`n$($tw5All.StdErr)" $dev234NoFloorLiteral)) "no $dev234NoFloorLiteral" "$($tw5All.StdOut)`n$($tw5All.StdErr)"
    $tw5SyncRoles = Invoke-IsolatedPwsh -HomeDir $tw5Home -File $syncScript -ArgumentList @('-SyncRoles', '-SeatMapPath', $tw5MapPath)
    Assert-True 'TW5 -SyncRoles with unrelated incapable seat: exit 0' ($tw5SyncRoles.ExitCode -eq 0) '0' ([string]$tw5SyncRoles.ExitCode)
    Assert-True 'TW5 -SyncRoles: no target runtime-floor error' (-not (Test-TextContains "$($tw5SyncRoles.StdOut)`n$($tw5SyncRoles.StdErr)" $dev234NoFloorLiteral)) "no $dev234NoFloorLiteral" "$($tw5SyncRoles.StdOut)`n$($tw5SyncRoles.StdErr)"
    $tw5SyncNotes = Invoke-IsolatedPwsh -HomeDir $tw5Home -File $syncScript -ArgumentList @('-SyncNotes', '-SeatMapPath', $tw5MapPath)
    Assert-True 'TW5 -SyncNotes with unrelated incapable seat: exit 0' ($tw5SyncNotes.ExitCode -eq 0) '0' ([string]$tw5SyncNotes.ExitCode)
    Assert-True 'TW5 -SyncNotes: no target runtime-floor error' (-not (Test-TextContains "$($tw5SyncNotes.StdOut)`n$($tw5SyncNotes.StdErr)" $dev234NoFloorLiteral)) "no $dev234NoFloorLiteral" "$($tw5SyncNotes.StdOut)`n$($tw5SyncNotes.StdErr)"
}
finally {
    if ($null -ne $dev234AnvilRoleFile) {
        if ($dev234AnvilRoleHadFile) {
            [System.IO.File]::WriteAllBytes($dev234AnvilRoleFile, $dev234AnvilRolePriorBytes)
        }
        elseif (Test-Path -LiteralPath $dev234AnvilRoleFile) {
            Remove-Item -LiteralPath $dev234AnvilRoleFile -Force -ErrorAction SilentlyContinue
            if (-not $dev234AnvilRoleDirExisted -and (Test-Path -LiteralPath $dev234AnvilRoleDir)) {
                $dev234RoleDirRemaining = @(Get-ChildItem -LiteralPath $dev234AnvilRoleDir -Force -ErrorAction SilentlyContinue)
                if ($dev234RoleDirRemaining.Count -eq 0) {
                    Remove-Item -LiteralPath $dev234AnvilRoleDir -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    if (Test-Path -LiteralPath $isoHome) {
        Remove-Item -LiteralPath $isoHome -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $hadWorktreeMaestri) {
        if (Test-Path -LiteralPath $worktreeMaestri) {
            Remove-Item -LiteralPath $worktreeMaestri -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    elseif (-not $hadWorktreeRoles) {
        if (Test-Path -LiteralPath $worktreeRoles) {
            Remove-Item -LiteralPath $worktreeRoles -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Assert-True 'cleanup: isolated HOME removed' (-not (Test-Path -LiteralPath $isoHome)) 'removed' $isoHome

$realSwapExistsAfter = Test-Path -LiteralPath $realSwapLog
if ($realSwapExistsBefore) {
    $afterItem = Get-Item -LiteralPath $realSwapLog
    Assert-True 'real home swap log mtime unchanged' ($afterItem.LastWriteTimeUtc -eq $realSwapWriteBefore) ([string]$realSwapWriteBefore) ([string]$afterItem.LastWriteTimeUtc)
    Assert-True 'real home swap log length unchanged' ($afterItem.Length -eq $realSwapLenBefore) ([string]$realSwapLenBefore) ([string]$afterItem.Length)
}
else {
    Assert-True 'real home swap log not created' (-not $realSwapExistsAfter) 'absent' ([string]$realSwapExistsAfter)
}

$realMaestriSnapAfter = Get-TargetedMaestriSnapshot -Root $realMaestri
Assert-True 'real profile .maestri targeted snapshot unchanged' ($realMaestriSnapBefore -eq $realMaestriSnapAfter) $realMaestriSnapBefore $realMaestriSnapAfter

Write-Host ''
Write-Host "Test-SeatMapLive: $checks checks, $failures failures."
if ($failures -gt 0) { exit 1 }
exit 0
