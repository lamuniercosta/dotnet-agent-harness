#!/usr/bin/env pwsh
# Porcelain guard for scripts/local/context-floor-baseline.json, plus self-tests
# for the dirt and exceeded failure paths.
#
# Fail-fast (no Assert-That in the guard): dirty porcelain on the baseline file
# exits 1 before any measurement is parsed; git errors fail closed. After
# porcelain is clean, current host bytes are compared increase-only against the
# committed baseline (a decrease is clean by the ratchet contract).
#
# Legitimate floor increase — refresh, then commit the baseline in the same PR:
#   pwsh ./scripts/local/Report-ContextFloor.ps1 -Json -OutFile ./scripts/local/context-floor-baseline.json
#
# Never pass -OutFile to the reporter from this guard; measurements come from
# -Json on stdout.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$reporter = Join-Path $PSScriptRoot 'Report-ContextFloor.ps1'
$baselineRel = 'scripts/local/context-floor-baseline.json'
$committedBaseline = Join-Path $PSScriptRoot 'context-floor-baseline.json'

$checks = 0
$failures = 0
$temporaryFiles = [System.Collections.Generic.List[string]]::new()
$temporaryRoots = [System.Collections.Generic.List[string]]::new()

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')

    $script:checks++
    if ($Condition) {
        Write-Host "  ok    $Name"
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

function Invoke-GitAtRoot {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    try {
        $raw = & git -C $RepoRoot @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{
            Ok       = $false
            ExitCode = 1
            Output   = $_.Exception.Message
        }
    }

    if ($null -eq $code) {
        return [pscustomobject]@{
            Ok       = $false
            ExitCode = 1
            Output   = 'git did not report an exit code'
        }
    }

    $text = ''
    if ($null -ne $raw) {
        $text = (@($raw) | ForEach-Object { "$_" }) -join "`n"
    }

    return [pscustomobject]@{
        Ok       = ([int]$code -eq 0)
        ExitCode = [int]$code
        Output   = $text
    }
}

function Test-BaselinePorcelainClean {
    param(
        [string]$Porcelain,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($Porcelain)) {
        return [pscustomobject]@{
            Clean   = $true
            Message = ''
        }
    }

    return [pscustomobject]@{
        Clean   = $false
        Message = "pre-existing local modification detected: $RelativePath (uncommitted)"
    }
}

function Invoke-BaselinePorcelainGuard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $git = Invoke-GitAtRoot -RepoRoot $RepoRoot -ArgumentList @('status', '--porcelain', '--', $RelativePath)
    if (-not $git.Ok) {
        $detail = $git.Output
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "git status exited $($git.ExitCode)"
        }
        return [pscustomobject]@{
            ExitCode = 1
            Output   = "git error (fail closed): $detail"
            Stage    = 'git'
        }
    }

    $check = Test-BaselinePorcelainClean -Porcelain $git.Output -RelativePath $RelativePath
    if (-not $check.Clean) {
        return [pscustomobject]@{
            ExitCode = 1
            Output   = $check.Message
            Stage    = 'porcelain'
        }
    }

    return [pscustomobject]@{
        ExitCode = 0
        Output   = ''
        Stage    = 'porcelain'
    }
}

function ConvertFrom-JsonStdout {
    param([string]$Output)

    $start = $Output.IndexOf('{')
    $end = $Output.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
        throw "Reporter output did not contain a JSON object.`n$Output"
    }
    return $Output.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

function Get-CurrentFloorEvidence {
    param([Parameter(Mandatory)][string]$ReporterPath)

    $output = & pwsh -NoProfile -File $ReporterPath -Json 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Report-ContextFloor.ps1 -Json failed (exit $LASTEXITCODE): $output"
    }
    return ConvertFrom-JsonStdout $output
}

function Test-BaselineIncreaseOnly {
    param(
        $CurrentHosts,
        $BaselineHosts,
        [Parameter(Mandatory)][string]$BaselinePath
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('claude', 'codex', 'cursor')) {
        $currentProp = $CurrentHosts.PSObject.Properties[$name]
        $baseProp = $BaselineHosts.PSObject.Properties[$name]
        if ($null -eq $currentProp) {
            throw "Current measurement is missing host '$name'"
        }
        if ($null -eq $baseProp) {
            throw "Baseline is missing host '$name'"
        }
        $currentBytes = [int]$currentProp.Value.bytes
        $baseBytes = [int]$baseProp.Value.bytes
        if ($currentBytes -gt $baseBytes) {
            $messages.Add("${name} exceeded baseline: current=$currentBytes bytes, baseline=$baseBytes bytes")
        }
    }

    $exceeded = $messages.Count -gt 0
    $output = ''
    if ($exceeded) {
        $output = (@("baseline exceeded: $BaselinePath") + $messages.ToArray()) -join "`n"
    }

    return [pscustomobject]@{
        Exceeded = $exceeded
        Output   = $output
    }
}

function Invoke-BaselineExceededGuard {
    param(
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)][string]$BaselinePath
    )

    if (-not (Test-Path -LiteralPath $BaselinePath)) {
        throw "Missing baseline file: $BaselinePath"
    }
    $baselineJson = Get-Content -LiteralPath $BaselinePath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($baselineJson)) {
        throw "Baseline file is empty: $BaselinePath"
    }
    $baselineObj = $baselineJson | ConvertFrom-Json
    if ($null -eq $baselineObj.hosts) {
        throw "Baseline is missing hosts: $BaselinePath"
    }

    $cmp = Test-BaselineIncreaseOnly -CurrentHosts $Current.hosts -BaselineHosts $baselineObj.hosts -BaselinePath $BaselinePath
    if ($cmp.Exceeded) {
        return [pscustomobject]@{
            ExitCode = 1
            Output   = $cmp.Output
        }
    }

    return [pscustomobject]@{
        ExitCode = 0
        Output   = ''
    }
}

function New-TemporaryDirtyBaselineRepo {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('baseline-guard-dirt-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:temporaryRoots.Add($path)

    $init = Invoke-GitAtRoot -RepoRoot $path -ArgumentList @('init', '-q')
    if (-not $init.Ok) {
        throw "git init failed: $($init.Output)"
    }

    $localDir = Join-Path $path (Join-Path 'scripts' 'local')
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    $file = Join-Path $localDir 'context-floor-baseline.json'
    [System.IO.File]::WriteAllText($file, "{`"ok`":true}`n", [System.Text.UTF8Encoding]::new($false))

    $add = Invoke-GitAtRoot -RepoRoot $path -ArgumentList @('add', '--', $baselineRel)
    if (-not $add.Ok) {
        throw "git add failed: $($add.Output)"
    }

    $commit = Invoke-GitAtRoot -RepoRoot $path -ArgumentList @(
        '-c', 'user.email=dev-203@test.local',
        '-c', 'user.name=DEV-203',
        '-c', 'commit.gpgsign=false',
        'commit', '--no-gpg-sign', '--no-verify', '-q', '-m', 'init'
    )
    if (-not $commit.Ok) {
        throw "git commit failed: $($commit.Output)"
    }

    [System.IO.File]::WriteAllText($file, "{`"ok`":false}`n", [System.Text.UTF8Encoding]::new($false))
    return $path
}

try {
    Write-Host 'Baseline guard'

    $porcGuard = Invoke-BaselinePorcelainGuard -RepoRoot $repoRoot -RelativePath $baselineRel
    if ($porcGuard.ExitCode -ne 0) {
        Write-Host $porcGuard.Output
        exit 1
    }

    $evidence = Get-CurrentFloorEvidence -ReporterPath $reporter
    $exceededGuard = Invoke-BaselineExceededGuard -Current $evidence -BaselinePath $committedBaseline
    if ($exceededGuard.ExitCode -ne 0) {
        Write-Host $exceededGuard.Output
        exit 1
    }

    Write-Host '  porcelain clean; no host exceeds committed baseline'

    Write-Host ''
    Write-Host 'Baseline guard — self-tests'

    $dirtExit = $null
    $dirtOutput = ''
    try {
        $dirtRoot = New-TemporaryDirtyBaselineRepo
        $dirtResult = Invoke-BaselinePorcelainGuard -RepoRoot $dirtRoot -RelativePath $baselineRel
        $dirtExit = $dirtResult.ExitCode
        $dirtOutput = $dirtResult.Output
    }
    catch {
        $dirtExit = -1
        $dirtOutput = $_.Exception.Message
    }
    Assert-That 'porcelain dirt path exits 1' ($dirtExit -eq 1) $dirtOutput
    Assert-That 'porcelain dirt output mentions uncommitted' ($dirtOutput -match 'uncommitted') $dirtOutput
    Assert-That 'porcelain dirt output names the baseline file' ($dirtOutput -match [regex]::Escape($baselineRel)) $dirtOutput

    $tempBaseline = Join-Path ([System.IO.Path]::GetTempPath()) ('context-floor-baseline-guard-' + [guid]::NewGuid().ToString('N') + '.json')
    $temporaryFiles.Add($tempBaseline)
    Copy-Item -LiteralPath $committedBaseline -Destination $tempBaseline -Force

    $tempObj = Get-Content -LiteralPath $tempBaseline -Raw -Encoding utf8 | ConvertFrom-Json
    $currentClaude = [int]$evidence.hosts.claude.bytes
    $lowered = [Math]::Max(0, $currentClaude - 1)
    $tempObj.hosts.claude.bytes = $lowered
    $tempJson = $tempObj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($tempBaseline, ($tempJson.TrimEnd() + "`n"), [System.Text.UTF8Encoding]::new($false))

    $exceededResult = Invoke-BaselineExceededGuard -Current $evidence -BaselinePath $tempBaseline
    Assert-That 'exceeded path exits 1 when a host baseline is lowered' ($exceededResult.ExitCode -eq 1) $exceededResult.Output
    Assert-That 'exceeded output contains exceeded' ($exceededResult.Output -match 'exceeded') $exceededResult.Output
    Assert-That 'exceeded output names the host' ($exceededResult.Output -match 'claude') $exceededResult.Output
    Assert-That 'exceeded output includes current and baseline bytes' (
        $exceededResult.Output -match [string]$currentClaude -and $exceededResult.Output -match [string]$lowered
    ) $exceededResult.Output
    Assert-That 'exceeded output names the baseline file' ($exceededResult.Output -match 'context-floor-baseline') $exceededResult.Output

    $happyPorc = Invoke-BaselinePorcelainGuard -RepoRoot $repoRoot -RelativePath $baselineRel
    $happyExceeded = Invoke-BaselineExceededGuard -Current $evidence -BaselinePath $committedBaseline
    Assert-That 'happy path: porcelain is clean on the committed baseline' ($happyPorc.ExitCode -eq 0) $happyPorc.Output
    Assert-That 'happy path: no host exceeds the committed baseline' ($happyExceeded.ExitCode -eq 0) $happyExceeded.Output
}
finally {
    foreach ($path in $temporaryFiles) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($root in $temporaryRoots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
Write-Host "Checks: $checks  Failures: $failures"
if ($failures -gt 0) { exit 1 }
exit 0
