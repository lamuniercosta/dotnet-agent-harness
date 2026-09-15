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

Write-Host 'Test-SeatMapLive (isolated HOME)'

try {
    New-Item -ItemType Directory -Path $isoHome -Force | Out-Null

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
    Assert-True 'A3: Test-ModelProbe -WhatIf exit 0' ($whatIf.ExitCode -eq 0) '0' ([string]$whatIf.ExitCode)
    Assert-True 'A3: git status --porcelain unchanged by Sync -All and probe -WhatIf' ($porcelainBefore -eq $porcelainAfter) $porcelainBefore $porcelainAfter
    if ([string]::IsNullOrWhiteSpace($porcelainBefore)) {
        Assert-True 'A3: git status --porcelain empty' ([string]::IsNullOrWhiteSpace($porcelainAfter)) '(empty)' $porcelainAfter
    }
    else {
        Write-Host "           (worktree already dirty; A3 empty-porcelain is the unchanged snapshot)" -ForegroundColor DarkGray
    }
    # Portal-swap live-server leg is a post-merge manual step; same write helper.

    # --- zero-workspace resolution -> A5, non-zero, no bind-time throw ---
    $zeroHome = Join-Path $isoHome 'zero-ws'
    New-Item -ItemType Directory -Path (Join-Path $zeroHome '.maestri' 'workspaces') -Force | Out-Null
    $zeroExpected = Join-Path $zeroHome '.maestri' 'workspaces' '<id>' 'seat-map.json'
    $zero = Invoke-IsolatedPwsh -HomeDir $zeroHome -File $syncScript -ArgumentList @('-Validate')
    Assert-True 'zero-workspace: exit non-zero' ($zero.ExitCode -ne 0) 'non-zero' ([string]$zero.ExitCode)
    Assert-True 'zero-workspace: stderr names expected path' (Test-TextContains $zero.StdErr $zeroExpected) $zeroExpected $zero.StdErr
    Assert-True 'zero-workspace: stderr names Init' (Test-TextContains $zero.StdErr 'Init') 'Init' $zero.StdErr
    Assert-True 'zero-workspace: no bind-time throw' (-not (Test-BindTimeThrow $zero.StdOut $zero.StdErr)) 'no ParameterBindingException' "$($zero.StdOut)$($zero.StdErr)"

    # --- two-workspace (both match) resolution -> A5, non-zero, no bind-time throw ---
    $twoHome = Join-Path $isoHome 'two-ws'
    $twoA = New-WorkspaceDir -HomeDir $twoHome -WorkspaceId ([guid]::NewGuid().ToString()) -RepoRootHint $repoRoot
    $twoB = New-WorkspaceDir -HomeDir $twoHome -WorkspaceId ([guid]::NewGuid().ToString()) -RepoRootHint $repoRoot
    $null = $twoA; $null = $twoB
    $twoExpected = Join-Path $twoHome '.maestri' 'workspaces' '<id>' 'seat-map.json'
    $two = Invoke-IsolatedPwsh -HomeDir $twoHome -File $syncScript -ArgumentList @('-Validate')
    Assert-True 'two-workspace: exit non-zero' ($two.ExitCode -ne 0) 'non-zero' ([string]$two.ExitCode)
    Assert-True 'two-workspace: stderr names expected path' (Test-TextContains $two.StdErr $twoExpected) $twoExpected $two.StdErr
    Assert-True 'two-workspace: stderr names Init' (Test-TextContains $two.StdErr 'Init') 'Init' $two.StdErr
    Assert-True 'two-workspace: no bind-time throw' (-not (Test-BindTimeThrow $two.StdOut $two.StdErr)) 'no ParameterBindingException' "$($two.StdOut)$($two.StdErr)"

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
}
finally {
    if (Test-Path -LiteralPath $isoHome) {
        Remove-Item -LiteralPath $isoHome -Recurse -Force -ErrorAction SilentlyContinue
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
