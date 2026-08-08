#!/usr/bin/env pwsh
# Proves the route-map advisor resolves, classifies, and logs correctly, and
# that route-map.json itself is well-formed. Uses isolated temporary repo
# roots with their own harness.yml; never touches the real route log.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$harnessRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$pipelineTable = Join-Path $harnessRoot 'skills/pipeline/SKILL.md'
$advisor = Join-Path $PSScriptRoot 'Get-ModelRoute.ps1'
$deviation = Join-Path $PSScriptRoot 'Add-RouteDeviation.ps1'

. (Join-Path $harnessRoot 'packs/dotnet/scripts/_gate-common.ps1')
. (Join-Path $PSScriptRoot '_route-map.ps1')

$checks = 0
$failures = 0
$temporaryRoots = @()

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

function New-TemporaryRepoRoot {
    param([string]$HarnessYamlBody = '')

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('route-map-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    if ($HarnessYamlBody) {
        [System.IO.File]::WriteAllText((Join-Path $path 'harness.yml'), $HarnessYamlBody, [System.Text.UTF8Encoding]::new($false))
    }
    $script:temporaryRoots += $path
    return $path
}

Write-Host 'Route map — schema validity'

$map = Get-RouteMap
Assert-That 'route-map.json loads and validates' $true

foreach ($commandProp in $map.commands.PSObject.Properties) {
    $entries = @($commandProp.Value.route)
    $floorCount = @($entries | Where-Object {
        (Get-Member -InputObject $_ -Name 'floor' -ErrorAction SilentlyContinue) -and $_.floor -eq $true
    }).Count
    Assert-That "'$($commandProp.Name)' has exactly one floor" ($floorCount -eq 1)
}

Write-Host ''
Write-Host 'Route map — pipeline coverage'

if (Test-Path -LiteralPath $pipelineTable) {
    $pipelineText = Get-Content -LiteralPath $pipelineTable -Raw
    $stageCommands = [regex]::Matches($pipelineText, '`(/[a-z\-]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    foreach ($cmd in $stageCommands) {
        $has = Get-Member -InputObject $map.commands -Name $cmd -ErrorAction SilentlyContinue
        Assert-That "route map has a row for '$cmd' (from /pipeline stage table)" ($null -ne $has)
    }
}
else {
    Assert-That 'skills/pipeline/SKILL.md exists to check coverage against' $false 'File not found; coverage not checked.'
}

Write-Host ''
Write-Host 'Resolve-RouteChain — model resolution'

$pinnedRoot = New-TemporaryRepoRoot -HarnessYamlBody @'
agents:
  tiers:
    deep:
      claude:
        model: claude-opus-5
        effort: high
'@
$resolvedPinned = Resolve-RouteChain -Command '/implement' -Map $map -RepoRoot $pinnedRoot
$claudeDeepEntry = $resolvedPinned.Chain | Where-Object { $_.Host -eq 'claude' -and $_.Tier -eq 'deep' } | Select-Object -First 1
Assert-That 'a pinned tier resolves to its configured model' ($claudeDeepEntry.Model -eq 'claude-opus-5') "Got: $($claudeDeepEntry.Model)"
Assert-That 'a pinned tier is not reported unpinned' ($claudeDeepEntry.Unpinned -eq $false)
Assert-That 'a pinned tier carries its effort' ($claudeDeepEntry.Effort -eq 'high')

$unpinnedRoot = New-TemporaryRepoRoot
$resolvedUnpinned = Resolve-RouteChain -Command '/implement' -Map $map -RepoRoot $unpinnedRoot
$claudeDeepDefault = $resolvedUnpinned.Chain | Where-Object { $_.Host -eq 'claude' -and $_.Tier -eq 'deep' } | Select-Object -First 1
Assert-That 'an unpinned deep tier resolves to Unpinned=true, not a guess' ($claudeDeepDefault.Unpinned -eq $true)
Assert-That 'an unpinned deep tier carries no model' ($null -eq $claudeDeepDefault.Model)

$resolvedFastCommand = Resolve-RouteChain -Command '/task' -Map $map -RepoRoot $unpinnedRoot
$fastEntry = $resolvedFastCommand.Chain | Where-Object { $_.Tier -eq 'fast' } | Select-Object -First 1
Assert-That "'fast' is pinned by shipped default even with no harness.yml" ($null -ne $fastEntry -and $fastEntry.Unpinned -eq $false) "fastEntry: $($fastEntry | ConvertTo-Json -Compress)"

Assert-That 'resolving an unknown command returns null' ($null -eq (Resolve-RouteChain -Command '/does-not-exist' -Map $map -RepoRoot $unpinnedRoot))

# From here on, every CLI invocation touches the REAL route-log.jsonl (it has
# no -LogPath parameter — the log path is fixed beside the script). Back it up
# once and restore it in one top-level finally so no code path can leak a
# stray entry into the real log, unlike a per-section backup would.
$realLog = Get-RouteLogPath
$logBackupExisted = Test-Path -LiteralPath $realLog
$logBackupPath = "$realLog.testbackup"
if ($logBackupExisted) { Move-Item -LiteralPath $realLog -Destination $logBackupPath -Force }

try {
    Write-Host ''
    Write-Host 'Get-ModelRoute.ps1 — advisor CLI'

    & $advisor -Command '/refactor' -RepoRoot $unpinnedRoot | Out-Null
    Assert-That 'advisor exits 0 for a known command' ($LASTEXITCODE -eq 0)

    & $advisor -Command '/not-a-real-command' -RepoRoot $unpinnedRoot 2>$null | Out-Null
    Assert-That 'advisor exits non-zero for an unknown command' ($LASTEXITCODE -ne 0)

    if (Test-Path -LiteralPath $realLog) { Remove-Item -LiteralPath $realLog -Force }

    Write-Host ''
    Write-Host 'Get-ModelRoute.ps1 — logging'

    $loggedRoot = New-TemporaryRepoRoot
    & $advisor -Command '/implement' -RepoRoot $loggedRoot -Area 'frontend' | Out-Null
    $lines = @(Get-Content -LiteralPath $realLog)
    Assert-That 'one invocation appends exactly one log line' ($lines.Count -eq 1) "Got $($lines.Count) lines"

    $parsed = $lines[0] | ConvertFrom-Json
    Assert-That 'logged line records the command' ($parsed.command -eq '/implement')
    Assert-That 'logged line carries the -Area tag' ($parsed.area -eq 'frontend')
    Assert-That 'logged line has a chain' ($null -ne $parsed.chain -and @($parsed.chain).Count -gt 0)

    & $advisor -Command '/refactor' -RepoRoot $loggedRoot | Out-Null
    $linesNoArea = @(Get-Content -LiteralPath $realLog)
    $secondParsed = $linesNoArea[1] | ConvertFrom-Json
    Assert-That 'logged line omits area when not given' (-not (Get-Member -InputObject $secondParsed -Name 'area' -ErrorAction SilentlyContinue))

    if (Test-Path -LiteralPath $realLog) { Remove-Item -LiteralPath $realLog -Force }

    Write-Host ''
    Write-Host 'Add-RouteDeviation.ps1 — classification'

    $devRoot = New-TemporaryRepoRoot

    & $deviation -Command '/implement' -Ran 'claude:deep' -RepoRoot $devRoot | Out-Null
    $atHead = (Get-Content -LiteralPath $realLog | Select-Object -Last 1 | ConvertFrom-Json)
    Assert-That "running the head of the chain classifies as 'at-head'" ($atHead.classification -eq 'at-head')

    & $deviation -Command '/implement' -Ran 'claude:balanced' -RepoRoot $devRoot | Out-Null
    $withinRoute = (Get-Content -LiteralPath $realLog | Select-Object -Last 1 | ConvertFrom-Json)
    Assert-That "running the floor classifies as 'within-route', not 'floor-breach'" ($withinRoute.classification -eq 'within-route')

    & $deviation -Command '/implement' -Ran 'cursor:fast' -Note 'quota exhausted' -RepoRoot $devRoot | Out-Null
    $breach = (Get-Content -LiteralPath $realLog | Select-Object -Last 1 | ConvertFrom-Json)
    Assert-That "running below the floor classifies as 'floor-breach'" ($breach.classification -eq 'floor-breach')
    Assert-That 'floor-breach carries the note' ($breach.note -eq 'quota exhausted')

    & $deviation -Command '/implement' -Ran 'codex:balanced' -RepoRoot $devRoot | Out-Null
    $outside = (Get-Content -LiteralPath $realLog | Select-Object -Last 1 | ConvertFrom-Json)
    Assert-That "running something outside the chain entirely classifies as 'floor-breach'" ($outside.classification -eq 'floor-breach')
}
finally {
    if (Test-Path -LiteralPath $realLog) { Remove-Item -LiteralPath $realLog -Force }
    if ($logBackupExisted) { Move-Item -LiteralPath $logBackupPath -Destination $realLog -Force }
}

Write-Host ''
Write-Host 'Packaged tree isolation'

$packagedTouch = git -C $harnessRoot status --porcelain -- skills agents install.ps1 2>$null
Assert-That 'packaged skills/agents/install.ps1 are untouched by this test run' ([string]::IsNullOrWhiteSpace($packagedTouch)) $packagedTouch

foreach ($root in $temporaryRoots) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Checks: $checks  Failures: $failures"
if ($failures -gt 0) { exit 1 }
exit 0
