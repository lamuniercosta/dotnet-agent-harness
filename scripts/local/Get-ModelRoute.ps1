#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Recommends which host and tier to run a pipeline command on.

.DESCRIPTION
  Repo-local advisor over scripts/local/route-map.json (see
  docs/adr/0008-route-map-records-work-demands.md). Prints the command's
  preference-ordered chain, resolved against the TARGET repo's harness.yml
  (agents.tiers), with the floor marked. It does not launch, configure, or
  choose anything — reading the chain and picking what you still have
  quota for is a human decision.

  Every invocation appends one line to scripts/local/route-log.jsonl
  (gitignored). To log what you actually ran, especially when it differs
  from the recommendation, use Add-RouteDeviation.ps1 afterward.

.PARAMETER Command
  A pipeline command, e.g. '/implement'. Must match a key in route-map.json.

.PARAMETER RepoRoot
  The repo whose harness.yml (agents.tiers) resolves tiers to models. This is
  the repo the WORK happens in, which may not be the current directory —
  defaults to the current repo root when omitted.

.PARAMETER Area
  Optional free-text tag for the kind of work (e.g. 'frontend'). Not
  validated against a taxonomy; the log is meant to be read later to find
  what taxonomy, if any, actually predicts a good route.

.PARAMETER NoLog
  Skip the log line. For dry runs and tests.

.EXAMPLE
  ./scripts/local/Get-ModelRoute.ps1 -Command /implement -RepoRoot ../LamuFlix -Area frontend
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Command,

    [string]$RepoRoot,

    [string]$Area,

    [switch]$NoLog,

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

if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$map = Get-RouteMap
$resolved = Resolve-RouteChain -Command $Command -Map $map -RepoRoot $RepoRoot

if ($null -eq $resolved) {
    $known = ($map.commands.PSObject.Properties.Name | Sort-Object) -join ', '
    Write-Warning "'$Command' is not in the route map. Known commands: $known"
    exit 1
}

Write-Host "Command: $Command"
Write-Host "Repo:    $RepoRoot"
Write-Host "Why:     $($resolved.Why)"
Write-Host ''
Write-Host 'Route (best first):'
foreach ($entry in $resolved.Chain) {
    Write-Host "  $(Format-RouteEntry -Entry $entry)"
}

# Only a KNOWN host's unpinned tier is a fixable config gap. Suggesting a pin
# for a host agents.tiers has no schema for would send the user to an edit the
# parser rejects.
$fixableUnpinned = @($resolved.Chain | Where-Object { $_.Unpinned -and $_.KnownHost }).Count -gt 0
$hostLevelOnly = @($resolved.Chain | Where-Object { -not $_.KnownHost })

if ($fixableUnpinned) {
    Write-Host ''
    Write-Host "Some tiers are unpinned in this repo's harness.yml — pin 'agents.tiers.<tier>.<host>.model' there for a concrete model." -ForegroundColor DarkGray
}
if ($hostLevelOnly.Count -gt 0) {
    $uniqueHosts = @($hostLevelOnly | ForEach-Object { $_.Host } | Sort-Object -Unique)
    $names = $uniqueHosts -join ', '
    $verb = if ($uniqueHosts.Count -eq 1) { 'sits' } else { 'sit' }
    Write-Host "$names $verb outside agents.tiers, so the tier is advice about what to select in that tool, not a resolved model." -ForegroundColor DarkGray
}

if (-not $NoLog) {
    $chainForLog = @($resolved.Chain | ForEach-Object {
        @{ host = $_.Host; tier = $_.Tier; model = $_.Model; unpinned = $_.Unpinned; floor = $_.IsFloor }
    })
    $entry = @{
        kind    = 'recommendation'
        command = $Command
        repo    = $RepoRoot
        chain   = $chainForLog
    }
    if ($Area) { $entry['area'] = $Area }
    Write-RouteLogEntry -Entry $entry
}

exit 0
