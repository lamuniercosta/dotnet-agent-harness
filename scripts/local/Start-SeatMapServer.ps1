<#
.SYNOPSIS
    Localhost HTTP server for the Maestri seat-map portal (port 8765).
.DESCRIPTION
    Serves artifacts/seat-map-selector.html and applies rung selections:
    preflights target-swap runtime FLOOR with the shared helper, persists any
    declared activeRung on the listener's seat-map, then runs Sync-SeatMap.ps1
    as a child to rewrite role chains and canvas notes, and optionally runs
    `maestri recruit --replace`. POST endpoints require the per-session token
    printed at startup. CORS is restricted to localhost. Fail-closed swaps
    (undeclared rung, no capable runtime floor) leave the seat-map unchanged.
.PARAMETER Port
    HTTP port to bind (default 8765).
.PARAMETER WorkspaceId
    Maestri workspace UUID. Auto-discovered when omitted.
.PARAMETER UiPath
    Path to the HTML artifact. Defaults to artifacts/seat-map-selector.html
    under the repo root. Missing artifact is a hard error.
.PARAMETER SeatMapPath
    Path to seat-map.json. Empty (default) resolves the live workspace path
    lazily after helpers are loaded. Explicit -SeatMapPath beats discovery.
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$WorkspaceId,
    [string]$UiPath,
    [string]$SeatMapPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_seat-map.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
$resolvedMap = Resolve-LiveSeatMapPath -SeatMapPath $SeatMapPath -WorkspaceId $WorkspaceId -RepoRoot $repoRoot
$seatMapPath = $resolvedMap.Path
$workspaceIdForLog = [string]$resolvedMap.WorkspaceId
if ([string]::IsNullOrWhiteSpace($UiPath)) {
    $UiPath = Join-Path $repoRoot 'artifacts' 'seat-map-selector.html'
}

if (-not (Test-Path -LiteralPath $UiPath)) {
    throw "Seat map UI artifact missing: $UiPath"
}
if (-not $resolvedMap.Ok) {
    Write-SeatMapResolutionFailureMessage -ResolverError ([string]$resolvedMap.Error)
    exit 1
}
if (-not (Test-Path -LiteralPath $seatMapPath)) {
    Write-SeatMapMissingMessage -Path $seatMapPath
    exit 1
}

$initialMapObj = Get-Content -LiteralPath $seatMapPath -Raw | ConvertFrom-Json
$initialViolations = @(Get-SeatMapViolations -Map $initialMapObj)
if ($initialViolations.Count -gt 0) {
    $initialViolations | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

$sessionToken = [guid]::NewGuid().ToString('N')
$prefix = "http://localhost:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.IgnoreWriteExceptions = $true

function Test-LocalhostOrigin {
    param([string]$Origin)
    if ([string]::IsNullOrWhiteSpace($Origin)) { return $true }
    return [bool]($Origin -match '^https?://(localhost|127\.0\.0\.1)(:\d+)?$')
}

function Send-HttpResponse {
    param(
        $Context,
        [string]$Content,
        [string]$ContentType = 'text/html; charset=utf-8',
        [int]$StatusCode = 200,
        [string]$Origin
    )
    $res = $Context.Response
    $res.StatusCode = $StatusCode
    $res.ContentType = $ContentType
    if (Test-LocalhostOrigin -Origin $Origin) {
        if (-not [string]::IsNullOrWhiteSpace($Origin)) {
            $res.Headers.Add('Access-Control-Allow-Origin', $Origin)
        } else {
            $res.Headers.Add('Access-Control-Allow-Origin', 'http://localhost')
        }
        $res.Headers.Add('Vary', 'Origin')
        $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, X-Seat-Map-Token')
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Get-RequestToken {
    param($Request)
    return [string]$Request.Headers['X-Seat-Map-Token']
}

function Get-SeatMapPathHomeContext {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $null
    }
    $wsDir = [System.IO.Path]::GetDirectoryName($full)
    $wsRoot = [System.IO.Path]::GetDirectoryName($wsDir)
    $maestriDir = [System.IO.Path]::GetDirectoryName($wsRoot)
    $homeDir = [System.IO.Path]::GetDirectoryName($maestriDir)
    if ([string]::IsNullOrWhiteSpace($wsDir) -or [string]::IsNullOrWhiteSpace($wsRoot) -or [string]::IsNullOrWhiteSpace($maestriDir) -or [string]::IsNullOrWhiteSpace($homeDir)) {
        return $null
    }
    if (-not [string]::Equals([System.IO.Path]::GetFileName($wsRoot), 'workspaces', [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    if (-not [string]::Equals([System.IO.Path]::GetFileName($maestriDir), '.maestri', [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return [pscustomobject]@{
        Home        = $homeDir
        WorkspaceId = [System.IO.Path]::GetFileName($wsDir)
    }
}

function Stop-OtherSeatMapServerProcesses {
    $mine = $PID
    if ($IsWindows) {
        foreach ($procName in @('pwsh.exe', 'powershell.exe')) {
            Get-CimInstance -ClassName Win32_Process -Filter "Name = '$procName'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessId -ne $mine -and ([string]$_.CommandLine -match 'Start-SeatMapServer\.ps1') } |
                ForEach-Object {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
        }
    } else {
        Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $mine } |
            ForEach-Object {
                $cl = ''
                $clPath = "/proc/$($_.Id)/cmdline"
                if (Test-Path -LiteralPath $clPath) {
                    try {
                        $cl = [System.IO.File]::ReadAllText($clPath)
                    } catch {
                        $cl = ''
                    }
                }
                if ($cl -match 'Start-SeatMapServer\.ps1') {
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                }
            }
    }
    Start-Sleep -Milliseconds 400
}

function Invoke-SeatMapSyncChild {
    param(
        [string]$SeatMapPath,
        [string]$SeatId,
        [string]$RungName,
        [string]$WorkspaceId
    )
    $pwshExe = (Get-Command pwsh).Source
    $childScript = Join-Path $PSScriptRoot 'Sync-SeatMap.ps1'
    $mapHome = Get-SeatMapPathHomeContext -Path $SeatMapPath
    $childWorkspaceId = $WorkspaceId
    if ([string]::IsNullOrWhiteSpace($childWorkspaceId) -and $null -ne $mapHome) {
        $childWorkspaceId = [string]$mapHome.WorkspaceId
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $repoRoot
    if ($null -ne $mapHome) {
        $psi.Environment['HOME'] = [string]$mapHome.Home
        $psi.Environment['USERPROFILE'] = [string]$mapHome.Home
    }
    foreach ($a in @(
            '-NoProfile', '-File', $childScript,
            '-SeatMapPath', $SeatMapPath,
            '-Seat', $SeatId,
            '-Rung', $RungName,
            '-SyncRoles',
            '-SyncNotes'
        )) {
        [void]$psi.ArgumentList.Add($a)
    }
    if (-not [string]::IsNullOrWhiteSpace($childWorkspaceId)) {
        [void]$psi.ArgumentList.Add('-WorkspaceId')
        [void]$psi.ArgumentList.Add($childWorkspaceId)
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) {
        $reapId = $p.Id
        try { $p.Kill($true) } catch { }
        [void]$p.WaitForExit(5000)
        if (-not $p.HasExited) {
            Stop-Process -Id $reapId -Force -ErrorAction SilentlyContinue
            [void]$p.WaitForExit(2000)
        }
    }
    # Parameterless WaitForExit latches ExitCode after redirected IO (Unix race:
    # the timeout overload can return true with ExitCode still 0).
    if ($p.HasExited) { $p.WaitForExit() }
    $out = $stdoutTask.GetAwaiter().GetResult()
    $err = $stderrTask.GetAwaiter().GetResult()
    if (-not [string]::IsNullOrWhiteSpace($out)) { Write-Host $out }
    if (-not [string]::IsNullOrWhiteSpace($err)) { Write-Warning $err }
    if (-not $p.HasExited) { return 1 }
    return [int]$p.ExitCode
}

function Apply-SeatRung {
    param(
        [string]$SeatId,
        [string]$RungName
    )

    $map = Get-Content -LiteralPath $seatMapPath -Raw | ConvertFrom-Json
    $target = $null
    foreach ($s in @($map.seats)) {
        if ($s.id -eq $SeatId -or $s.codename -eq $SeatId) {
            $target = $s
            break
        }
    }
    if ($null -eq $target) {
        return @{ success = $false; error = "Seat '$SeatId' not found" }
    }
    $targetRungCell = Get-SeatMapRungByName -Seat $target -Name $RungName
    if ($null -eq $targetRungCell) {
        return @{ success = $false; error = "Seat '$SeatId' has no '$RungName' rung" }
    }

    $previousRung = Get-SeatActiveRungName -Seat $target
    $previousLaunch = ''
    $previousPool = ''
    $prevCell = Get-SeatMapRungByName -Seat $target -Name $previousRung
    if ($null -ne $prevCell) {
        if (Test-JsonProperty -Object $prevCell -Name 'launch') { $previousLaunch = [string]$prevCell.launch }
        if (Test-JsonProperty -Object $prevCell -Name 'pool') { $previousPool = [string]$prevCell.pool }
    }

    $resolvedFloor = Resolve-SeatRuntimeFloor -Map $map -Seat $target
    if (-not $resolvedFloor.Ok) {
        return @{ success = $false; error = [string]$resolvedFloor.Error }
    }

    $violations = @(Get-SeatMapViolations -Map $map)
    if ($violations.Count -gt 0) {
        return @{ success = $false; error = 'Invariant check failed'; violations = $violations }
    }

    $targetId = [string]$target.id
    $syncExit = Invoke-SeatMapSyncChild -SeatMapPath $seatMapPath -SeatId $targetId -RungName $RungName -WorkspaceId $workspaceIdForLog
    if ($syncExit -ne 0) {
        return @{
            success = $false
            error   = "Sync-SeatMap.ps1 exited $syncExit"
            seat    = $target.codename
        }
    }

    # $target still has the pre-sync activeRung; rungs are unchanged. When the
    # requested rung is the floor-role rung, the portal launch is the resolved runtime FLOOR.
    $rungCell = Get-SeatMapRungByName -Seat $target -Name $RungName
    if (Test-SeatMapRungIsFloorRole -Seat $target -RungName $RungName -Cell $rungCell) {
        $launch = [string]$resolvedFloor.Launch
        $pool = [string]$resolvedFloor.Pool
    } else {
        $launch = if ($null -ne $rungCell -and (Test-JsonProperty -Object $rungCell -Name 'launch')) { [string]$rungCell.launch } else { '' }
        $pool = if ($null -ne $rungCell -and (Test-JsonProperty -Object $rungCell -Name 'pool')) { [string]$rungCell.pool } else { '' }
    }
    $codeName = if (Test-JsonProperty -Object $target -Name 'codename') { [string]$target.codename } else { '' }
    $preset = if (Test-JsonProperty -Object $target -Name 'preset') { [string]$target.preset } else { '' }
    $recruitCmd = Get-SeatMapRecruitCommand -Codename $codeName -Preset $preset -Launch $launch
    $liveSwapped = $false
    $detail = 'map+roles+notes'
    if ($env:MAESTRI_PIPE) {
        try {
            $cliPath = if ($env:MAESTRI_CLI) { $env:MAESTRI_CLI } else { 'maestri' }
            # Discard recruit stdout so CLI chatter cannot join this function's
            # return value. The portal handler reads .success; extra success-stream
            # objects turn $result into an array and StrictMode throws
            # "The property 'success' cannot be found on this object."
            $null = & $cliPath recruit $target.codename --preset $target.preset --command $launch --replace $target.codename
            $liveSwapped = ($LASTEXITCODE -eq 0)
            $detail = if ($liveSwapped) { 'recruit --replace' } else { "recruit exit $LASTEXITCODE" }
        } catch {
            $detail = "recruit failed: $_"
            Write-Warning $detail
        }
    }
    Write-SeatMapSwapLog -Seat $target.codename -Rung $RungName -Launch $launch -Pool $pool -PreviousActiveRung $previousRung -PreviousLaunch $previousLaunch -PreviousPool $previousPool -LiveSwapped $liveSwapped -Detail $detail -WorkspaceId $workspaceIdForLog

    return @{
        success        = $true
        seat           = $target.codename
        activeRung     = $RungName
        launch         = $launch
        pool           = $pool
        liveSwapped    = $liveSwapped
        recruitCommand = $recruitCmd
    }
}

Stop-OtherSeatMapServerProcesses
try {
    $listener.Start()
    Write-Host '==========================================================' -ForegroundColor Cyan
    Write-Host " Maestri Seat Map server: $prefix" -ForegroundColor Green
    Write-Host " POST token (X-Seat-Map-Token): $sessionToken" -ForegroundColor Yellow
    Write-Host ' CORS: localhost / 127.0.0.1 only' -ForegroundColor Yellow
    Write-Host ' Press Ctrl+C to stop.' -ForegroundColor Gray
    Write-Host '==========================================================' -ForegroundColor Cyan
} catch {
    Write-Error "Failed to start HttpListener on $prefix. Error: $_"
    exit 1
}

try {
    while ($listener.IsListening) {
      $context = $null
      $origin = ''
      try {
        $context = $listener.GetContext()
        $req = $context.Request
        $origin = [string]$req.Headers['Origin']

        if (-not (Test-LocalhostOrigin -Origin $origin)) {
            Send-HttpResponse -Context $context -Content '{"error":"origin not allowed"}' -ContentType 'application/json' -StatusCode 403 -Origin $origin
            continue
        }

        if ($req.HttpMethod -eq 'OPTIONS') {
            Send-HttpResponse -Context $context -Content '' -ContentType 'text/plain' -StatusCode 204 -Origin $origin
            continue
        }

        $urlPath = $req.Url.AbsolutePath

        if ($urlPath -eq '/' -or $urlPath -eq '/index.html') {
            $html = Get-Content -LiteralPath $UiPath -Raw
            $html = $html.Replace('__SEAT_MAP_TOKEN__', $sessionToken)
            Send-HttpResponse -Context $context -Content $html -ContentType 'text/html; charset=utf-8' -Origin $origin
        }
        elseif ($urlPath -eq '/api/seats' -and $req.HttpMethod -eq 'GET') {
            $json = Get-Content -LiteralPath $seatMapPath -Raw
            Send-HttpResponse -Context $context -Content $json -ContentType 'application/json' -Origin $origin
        }
        elseif ($urlPath -eq '/api/seats/set' -and $req.HttpMethod -eq 'POST') {
            $token = Get-RequestToken -Request $req
            if ($token -ne $sessionToken) {
                Send-HttpResponse -Context $context -Content '{"error":"missing or invalid token"}' -ContentType 'application/json' -StatusCode 401 -Origin $origin
                continue
            }
            $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
            try {
                $body = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
            $payload = $null
            try {
                $payload = $body | ConvertFrom-Json
            } catch {
                Send-HttpResponse -Context $context -Content '{"error":"malformed JSON"}' -ContentType 'application/json' -StatusCode 400 -Origin $origin
                continue
            }
            if ($null -eq $payload) {
                Send-HttpResponse -Context $context -Content '{"error":"malformed JSON"}' -ContentType 'application/json' -StatusCode 400 -Origin $origin
                continue
            }
            $seatId = ''
            $rungName = ''
            if (Test-JsonProperty -Object $payload -Name 'seatId') { $seatId = [string]$payload.seatId }
            if (Test-JsonProperty -Object $payload -Name 'rung') { $rungName = [string]$payload.rung }
            if ([string]::IsNullOrWhiteSpace($rungName) -and (Test-JsonProperty -Object $payload -Name 'activeRung')) {
                $rungName = [string]$payload.activeRung
            }
            if ([string]::IsNullOrWhiteSpace($seatId) -or [string]::IsNullOrWhiteSpace($rungName)) {
                Send-HttpResponse -Context $context -Content '{"error":"missing seatId or rung"}' -ContentType 'application/json' -StatusCode 400 -Origin $origin
                continue
            }
            $result = Apply-SeatRung -SeatId $seatId -RungName $rungName
            $status = if ($result.success) { 200 } else { 400 }
            Send-HttpResponse -Context $context -Content ($result | ConvertTo-Json -Depth 6) -ContentType 'application/json' -StatusCode $status -Origin $origin
        }
        else {
            Send-HttpResponse -Context $context -Content '{"error":"not found"}' -ContentType 'application/json' -StatusCode 404 -Origin $origin
        }
      } catch {
        Write-Warning "Error handling request: $_"
        if ($null -ne $context) {
            try {
                Send-HttpResponse -Context $context -Content '{"error":"request failed"}' -ContentType 'application/json' -StatusCode 400 -Origin $origin
            } catch {
                Write-Warning "Could not send error response: $_"
            }
        }
      }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
