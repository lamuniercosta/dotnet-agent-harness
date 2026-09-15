<#
.SYNOPSIS
    Localhost HTTP server for the Maestri seat-map portal (port 8765).
.DESCRIPTION
    Serves artifacts/seat-map-selector.html and applies rung selections:
    writes activeRung on seat-map.json (same contract as Sync-SeatMap.ps1),
    rewrites role chains (array order, one terminal (FLOOR). marker), updates canvas notes, and
    optionally runs `maestri recruit --replace`. POST endpoints require the
    per-session token printed at startup. CORS is restricted to localhost.
    Writes are validated against the same charter invariants as Test-SeatMap.
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

$mapObj = Get-Content -LiteralPath $seatMapPath -Raw | ConvertFrom-Json
$mapViolations = @(Get-SeatMapViolations -Map $mapObj)
if ($mapViolations.Count -gt 0) {
    $mapViolations | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

$sessionToken = [guid]::NewGuid().ToString('N')
$prefix = "http://localhost:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

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

function Apply-SeatRung {
    param(
        [string]$SeatId,
        [string]$RungName
    )

    $map = Get-Content -LiteralPath $seatMapPath -Raw | ConvertFrom-Json
    $preViolations = @(Get-SeatMapViolations -Map $map)
    if ($preViolations.Count -gt 0) {
        return @{ success = $false; error = [string]$preViolations[0]; violations = $preViolations }
    }

    $target = Find-SeatMapSeat -Map $map -Name $SeatId
    if ($null -eq $target) {
        return @{ success = $false; error = "Seat '$SeatId' not found" }
    }

    $cell = Get-SeatMapRungByName -Seat $target -Name $RungName
    if ($null -eq $cell) {
        return @{ success = $false; error = "Seat '$SeatId' has no '$RungName' rung" }
    }

    $previousRung = Get-SeatMapActiveRungName -Seat $target
    if ([string]::IsNullOrWhiteSpace($previousRung)) { $previousRung = '' }
    $previousLaunch = ''
    $previousPool = ''
    $prevCell = Get-SeatMapRungByName -Seat $target -Name $previousRung
    if ($null -ne $prevCell) {
        if (Test-JsonProperty -Object $prevCell -Name 'launch') { $previousLaunch = [string]$prevCell.launch }
        if (Test-JsonProperty -Object $prevCell -Name 'pool') { $previousPool = [string]$prevCell.pool }
    }

    $target.activeRung = $RungName
    $violations = @(Get-SeatMapViolations -Map $map)
    if ($violations.Count -gt 0) {
        return @{ success = $false; error = 'Invariant check failed'; violations = $violations }
    }
    $mapJson = $map | ConvertTo-Json -Depth 12
    Save-SeatMapFile -Path $seatMapPath -Content ($mapJson + [Environment]::NewLine)

    $syncScript = Join-Path $PSScriptRoot 'Sync-SeatMap.ps1'
    $syncArgs = @{
        SeatMapPath = $seatMapPath
        Seat        = $target.id
        Rung        = $RungName
        SyncRoles   = $true
        SyncNotes   = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        $syncArgs.WorkspaceId = $WorkspaceId
    }
    & $syncScript @syncArgs
    $syncExit = $LASTEXITCODE
    if ($syncExit -ne 0) {
        $failLaunch = if (Test-JsonProperty -Object $cell -Name 'launch') { [string]$cell.launch } else { '' }
        $failPool = if (Test-JsonProperty -Object $cell -Name 'pool') { [string]$cell.pool } else { '' }
        Write-SeatMapSwapLog -Seat $target.codename -Rung $RungName -Launch $failLaunch -Pool $failPool -PreviousActiveRung $previousRung -PreviousLaunch $previousLaunch -PreviousPool $previousPool -LiveSwapped $false -Detail "partialSync exit $syncExit" -WorkspaceId $workspaceIdForLog
        return @{
            success     = $false
            error       = "Partial sync failure: Sync-SeatMap.ps1 exited $syncExit"
            partialSync = $true
            seat        = $target.codename
            activeRung  = $RungName
        }
    }

    $launch = if (Test-JsonProperty -Object $cell -Name 'launch') { [string]$cell.launch } else { '' }
    $pool = if (Test-JsonProperty -Object $cell -Name 'pool') { [string]$cell.pool } else { '' }
    $codeName = if (Test-JsonProperty -Object $target -Name 'codename') { [string]$target.codename } else { '' }
    $preset = if (Test-JsonProperty -Object $target -Name 'preset') { [string]$target.preset } else { '' }
    $recruitCmd = Get-SeatMapRecruitCommand -Codename $codeName -Preset $preset -Launch $launch
    $liveSwapped = $false
    $detail = 'map+roles+notes'
    if ($env:MAESTRI_PIPE) {
        try {
            $cliPath = if ($env:MAESTRI_CLI) { $env:MAESTRI_CLI } else { 'maestri' }
            & $cliPath recruit $target.codename --preset $target.preset --command $launch --replace $target.codename
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
            $currentMap = $json | ConvertFrom-Json
            $getViolations = @(Get-SeatMapViolations -Map $currentMap)
            if ($getViolations.Count -gt 0) {
                $errBody = @{ error = [string]$getViolations[0]; violations = $getViolations } | ConvertTo-Json -Depth 4
                Send-HttpResponse -Context $context -Content $errBody -ContentType 'application/json' -StatusCode 400 -Origin $origin
                continue
            }
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
