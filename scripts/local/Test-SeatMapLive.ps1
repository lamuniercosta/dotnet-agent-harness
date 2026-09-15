#!/usr/bin/env pwsh
# Bar-proves DEV-239 A1, A3, A5 and override precedence against an isolated HOME.
# Does not touch the real user profile's ~/.maestri. Cleanup is enforced.
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
        $obj = [ordered]@{
            prompt = 'Model chain (best first): placeholder -> placeholder -> placeholder (FLOOR).'
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

$isoHome = Join-Path ([System.IO.Path]::GetTempPath()) ('seat-map-live-' + [guid]::NewGuid().ToString('N'))
if ([string]::Equals((ConvertTo-Fwd $isoHome).TrimEnd('/'), (ConvertTo-Fwd $realProfile).TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to isolate HOME onto the real user profile: $isoHome"
}

$worktreeMaestri = Join-Path $repoRoot '.maestri'
$worktreeRoles = Join-Path $worktreeMaestri 'roles'
$hadWorktreeMaestri = Test-Path -LiteralPath $worktreeMaestri
$hadWorktreeRoles = Test-Path -LiteralPath $worktreeRoles

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
    Assert-True 'override ModelProbe: exit 0 while live map missing' ($probeOverride.ExitCode -eq 0) '0' ([string]$probeOverride.ExitCode)
    Assert-True 'override ModelProbe: no A5 Init in stderr' (-not (Test-TextContains $probeOverride.StdErr 'Init')) 'no Init' $probeOverride.StdErr

    # Restore live map for A3.
    Copy-Item -LiteralPath $examplePath -Destination $livePath

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
    $altCell = Get-SeatMapRungByName -Seat $condSeat -Name 'alt'
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
        "`$serverProc = Start-Process pwsh -ArgumentList '-NoProfile', '-File', '$serverScriptLiteral', '-Port', '8792', '-SeatMapPath', '$quoteMapPathLiteral' -PassThru -RedirectStandardOutput (Join-Path '$isoHome' 'server-quote.log')"
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
        "    Stop-Process -Id `$serverProc.Id -Force -ErrorAction SilentlyContinue"
        "}"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($portalQuoteScript, $portalQuoteScriptBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $portalQuoteRes = Invoke-IsolatedPwsh -HomeDir $isoHome -File $portalQuoteScript
    Assert-True 'R1 A3 Start-SeatMapServer recruitCommand quoting: exit 0' ($portalQuoteRes.ExitCode -eq 0) '0' ("exit=$($portalQuoteRes.ExitCode)`n$($portalQuoteRes.StdOut)`n$($portalQuoteRes.StdErr)")

    # --- DEV-235 B4: Portal HTTP render + POST + activeRung readback ---
    $portalScript = Join-Path $isoHome 'test-portal.ps1'
    $serverScriptLiteral = $serverScript.Replace("'", "''")
    $portalScriptBody = @(
        "`$serverProc = Start-Process pwsh -ArgumentList '-NoProfile', '-File', '$serverScriptLiteral', '-Port', '8789', '-SeatMapPath', '$livePathLiteral' -PassThru -RedirectStandardOutput (Join-Path '$isoHome' 'server.log')"
        "Start-Sleep -Seconds 2"
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
        "} finally {"
        "    Stop-Process -Id `$serverProc.Id -Force -ErrorAction SilentlyContinue"
        "}"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($portalScript, $portalScriptBody + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $portalRes = Invoke-IsolatedPwsh -HomeDir $isoHome -File $portalScript
    Assert-True 'portal HTTP render+POST: exit 0' ($portalRes.ExitCode -eq 0) '0' ("exit=$($portalRes.ExitCode)`n$($portalRes.StdOut)`n$($portalRes.StdErr)")
    $portalReadbackMap = Get-Content -LiteralPath $livePath -Raw | ConvertFrom-Json
    $portalCondSeat = @($portalReadbackMap.seats | Where-Object { $_.id -eq 'conductor' })[0]
    Assert-True 'portal HTTP POST: activeRung readback confirmed alt' ($portalCondSeat.activeRung -eq 'alt') 'alt' ([string]$portalCondSeat.activeRung)

}
finally {
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

Write-Host ''
Write-Host "Test-SeatMapLive: $checks checks, $failures failures."
if ($failures -gt 0) { exit 1 }
exit 0
