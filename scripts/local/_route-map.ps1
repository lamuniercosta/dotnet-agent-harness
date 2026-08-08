#!/usr/bin/env pwsh
# Shared helpers for the route-map advisor (Get-ModelRoute.ps1,
# Add-RouteDeviation.ps1). See specs/046-route-map-advisor/brief.md and
# docs/adr/0008-route-map-records-work-demands.md.
#
# Dot-source from a script:  . (Join-Path $PSScriptRoot '_route-map.ps1')

Set-StrictMode -Version Latest

# Hosts agents.tiers can resolve a model for. A route entry naming any other
# host (Junie, Gemini, ...) is valid but resolves to no model — host-level
# advice only, never an error.
$script:RouteMapKnownHosts = @('claude', 'cursor', 'codex')
$script:RouteMapKnownTiers = @('fast', 'balanced', 'deep')

function Get-RouteMapPath {
    Join-Path $PSScriptRoot 'route-map.json'
}

function Get-RouteLogPath {
    # Gitignored: personal usage evidence, not the authored artifact.
    Join-Path $PSScriptRoot 'route-log.jsonl'
}

function Get-RouteMap {
    <#
      Loads and validates route-map.json. Throws on anything that would make a
      route unusable: missing why, no route, no exactly-one floor, or an
      unknown tier name. Unknown hosts are allowed — that's how Junie/Gemini
      rows will enter the map once the spike concludes.
    #>
    param([string]$Path)

    if (-not $Path) { $Path = Get-RouteMapPath }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Route map not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    $map = $null
    try { $map = $raw | ConvertFrom-Json } catch {
        throw "${Path}: not valid JSON: $($_.Exception.Message)"
    }

    if (-not (Get-Member -InputObject $map -Name 'commands' -ErrorAction SilentlyContinue)) {
        throw "${Path}: missing top-level 'commands' object."
    }

    foreach ($commandProp in $map.commands.PSObject.Properties) {
        $command = $commandProp.Name
        $row = $commandProp.Value

        $why = $null
        if (Get-Member -InputObject $row -Name 'why' -ErrorAction SilentlyContinue) { $why = $row.why }
        if ([string]::IsNullOrWhiteSpace($why)) {
            throw "${Path}: '$command' has no 'why'. Every row must record its reasoning."
        }

        if (-not (Get-Member -InputObject $row -Name 'route' -ErrorAction SilentlyContinue) -or
            $null -eq $row.route -or @($row.route).Count -eq 0) {
            throw "${Path}: '$command' has an empty route."
        }

        $entries = @($row.route)
        $floorCount = 0
        foreach ($entry in $entries) {
            if (-not (Get-Member -InputObject $entry -Name 'host' -ErrorAction SilentlyContinue) -or
                [string]::IsNullOrWhiteSpace($entry.host)) {
                throw "${Path}: '$command' has a route entry with no host."
            }
            $tier = $null
            if (Get-Member -InputObject $entry -Name 'tier' -ErrorAction SilentlyContinue) { $tier = $entry.tier }
            if ([string]::IsNullOrWhiteSpace($tier)) {
                throw "${Path}: '$command' has a route entry with no tier."
            }
            if ($script:RouteMapKnownTiers -notcontains $tier) {
                throw "${Path}: '$command' names unknown tier '$tier'. Known tiers: $($script:RouteMapKnownTiers -join ', ')."
            }
            if ((Get-Member -InputObject $entry -Name 'floor' -ErrorAction SilentlyContinue) -and $entry.floor -eq $true) {
                $floorCount++
            }
        }

        if ($floorCount -ne 1) {
            throw "${Path}: '$command' must mark exactly one route entry as the floor (found $floorCount)."
        }
    }

    return $map
}

function Resolve-RouteChain {
    <#
      Resolves one command's route against the TARGET repo's harness.yml
      (agents.tiers). Returns an ordered array of PSCustomObjects:
        Host, Tier, Model, Effort, Unpinned, IsFloor
      Model/Effort are $null and Unpinned is $true when the tier names
      'inherit' or the host carries no tier data at all (host-level advice).
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)]$Map,
        [string]$RepoRoot
    )

    if (-not (Get-Member -InputObject $Map.commands -Name $Command -ErrorAction SilentlyContinue)) {
        return $null
    }

    $row = $Map.commands.$Command
    $config = Get-HarnessConfig -RepoRoot $RepoRoot

    $chain = foreach ($entry in @($row.route)) {
        $hostName = $entry.host
        $tier = $entry.tier
        $isFloor = (Get-Member -InputObject $entry -Name 'floor' -ErrorAction SilentlyContinue) -and $entry.floor -eq $true

        $model = $null
        $effort = $null
        $unpinned = $true

        if ($script:RouteMapKnownHosts -contains $hostName) {
            $modelKey = "agents.tiers.$tier.$hostName.model"
            $effortKey = "agents.tiers.$tier.$hostName.effort"
            if ($config.ContainsKey($modelKey)) {
                $rawModel = $config[$modelKey]
                if ($rawModel -and $rawModel -ne 'inherit') {
                    $model = $rawModel
                    $effort = $config[$effortKey]
                    if ($effort -eq 'inherit') { $effort = $null }
                    $unpinned = $false
                }
            }
        }

        [PSCustomObject]@{
            Host      = $hostName
            Tier      = $tier
            Model     = $model
            Effort    = $effort
            Unpinned  = $unpinned
            # A host agents.tiers has no schema for (Junie, Gemini, ...) can
            # never resolve a model, so its Unpinned is not a fixable config
            # gap the way a known host's is. Callers must not tell the user
            # to pin something the schema will reject.
            KnownHost = ($script:RouteMapKnownHosts -contains $hostName)
            IsFloor   = [bool]$isFloor
        }
    }

    return [PSCustomObject]@{
        Command = $Command
        Why     = $row.why
        Chain   = @($chain)
    }
}

function Write-RouteLogEntry {
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [string]$LogPath
    )

    if (-not $LogPath) { $LogPath = Get-RouteLogPath }
    $Entry['ts'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    ($Entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $LogPath -Encoding utf8
}

function Format-RouteEntry {
    param([Parameter(Mandatory)]$Entry)

    $modelPart =
        if (-not $Entry.KnownHost) { 'host-level advice (no tier data)' }
        elseif ($Entry.Unpinned) { 'unpinned' }
        else { $Entry.Model }
    $effortPart = if ($Entry.Effort) { ", effort=$($Entry.Effort)" } else { '' }
    $floorTag = if ($Entry.IsFloor) { '  [floor]' } else { '' }
    "$($Entry.Host):$($Entry.Tier) -> $modelPart$effortPart$floorTag"
}
