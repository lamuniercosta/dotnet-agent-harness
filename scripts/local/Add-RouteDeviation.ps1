#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Records what you actually ran a command on, when it differs from the
  route map's recommendation.

.DESCRIPTION
  Repo-local companion to Get-ModelRoute.ps1. Appends one line to
  scripts/local/route-log.jsonl classifying what happened:

    within-route   - Ran on some option in the chain, just not the head.
    floor-breach   - Ran below the floor, or on something outside the chain
                     entirely. Recorded distinctly because this is the one
                     that matters: work knowingly done at reduced quality.
    at-head        - Matched the top recommendation. Logged too, so an
                     unannotated run is not silently indistinguishable from
                     one that was checked and confirmed.

  This script never launches or configures anything — it only classifies and
  logs a choice you already made.

.PARAMETER Command
  The pipeline command that was run, e.g. '/implement'.

.PARAMETER Ran
  What was actually used, as 'host:tier' (e.g. 'cursor:fast').

.PARAMETER RepoRoot
  The repo whose harness.yml resolves tiers to models. Defaults to the
  current repo root.

.PARAMETER Area
  Optional free-text tag, same convention as Get-ModelRoute.ps1.

.PARAMETER Note
  Optional free-text reason (e.g. 'Claude weekly limit hit').

.EXAMPLE
  ./scripts/local/Add-RouteDeviation.ps1 -Command /implement -Ran cursor:fast -Note 'Claude weekly limit hit'
#>
[CmdletBinding(DefaultParameterSetName = 'Log')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Log')]
    [string]$Command,

    [Parameter(Mandatory = $true, ParameterSetName = 'Log')]
    [string]$Ran,

    [string]$RepoRoot,

    [Parameter(ParameterSetName = 'Log')]
    [string]$Area,

    [Parameter(ParameterSetName = 'Log')]
    [string]$Note,

    # Own set so `-Help` alone binds without tripping the mandatory checks.
    [Parameter(Mandatory = $true, ParameterSetName = 'Help')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

. (Join-Path $PSScriptRoot '../../packs/dotnet/scripts/_gate-common.ps1')
. (Join-Path $PSScriptRoot '_route-map.ps1')

if ($Ran -notmatch '^([^:]+):([^:]+)$') {
    throw "-Ran must be 'host:tier', e.g. 'cursor:fast'. Got: $Ran"
}
$ranHost = $Matches[1]
$ranTier = $Matches[2]

if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$map = Get-RouteMap
$resolved = Resolve-RouteChain -Command $Command -Map $map -RepoRoot $RepoRoot

if ($null -eq $resolved) {
    $known = ($map.commands.PSObject.Properties.Name | Sort-Object) -join ', '
    Write-Warning "'$Command' is not in the route map. Known commands: $known"
    exit 1
}

$matchIndex = -1
for ($i = 0; $i -lt $resolved.Chain.Count; $i++) {
    if ($resolved.Chain[$i].Host -eq $ranHost -and $resolved.Chain[$i].Tier -eq $ranTier) {
        $matchIndex = $i
        break
    }
}

$floorIndex = -1
for ($i = 0; $i -lt $resolved.Chain.Count; $i++) {
    if ($resolved.Chain[$i].IsFloor) { $floorIndex = $i; break }
}

$classification =
    if ($matchIndex -eq -1) { 'floor-breach' }               # not in the chain at all
    elseif ($matchIndex -gt $floorIndex) { 'floor-breach' }  # in the chain, below the floor
    elseif ($matchIndex -eq 0) { 'at-head' }
    else { 'within-route' }

Write-Host "Command:        $Command"
Write-Host "Ran:            $Ran"
Write-Host "Classification: $classification"

$entry = @{
    kind           = 'deviation'
    command        = $Command
    repo           = $RepoRoot
    ran            = @{ host = $ranHost; tier = $ranTier }
    classification = $classification
}
if ($Area) { $entry['area'] = $Area }
if ($Note) { $entry['note'] = $Note }

Write-RouteLogEntry -Entry $entry
exit 0
