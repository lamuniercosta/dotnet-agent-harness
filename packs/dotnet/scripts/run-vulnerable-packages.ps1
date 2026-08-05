#!/usr/bin/env pwsh
# Vulnerable-package gate.
#
# Half of what a hosted static-analysis service contributes over Roslyn +
# InspectCode is supply-chain: a CVE in a transitive dependency that no code
# analyzer will ever see. This gate covers that half locally, with no account.
# CodeQL covers the other half (dataflow) post-PR in CI.
#
# Usage:
#   ./scripts/run-vulnerable-packages.ps1
#   ./scripts/run-vulnerable-packages.ps1 -Severity High
#   ./scripts/run-vulnerable-packages.ps1 -IncludeTransitive:$false
#
# Exit 0 = no findings at or above -Severity. Exit 1 = findings, or the scan
# could not run. A scan that could not run is never reported as a pass.

[CmdletBinding()]
param(
    [ValidateSet('Low', 'Moderate', 'High', 'Critical')]
    [string]$Severity,
    [nullable[bool]]$IncludeTransitive,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @'
Usage: run-vulnerable-packages.ps1 [-Severity <Low|Moderate|High|Critical>] [-IncludeTransitive <bool>]

Fails on any known-vulnerable NuGet package at or above the given severity.
Defaults come from harness.yml (gates.vulnerablePackages). With no -Severity,
ANY advisory fails - a known CVE in a shipped dependency is not a warning.
'@
    exit 0
}

$repoRoot = Get-RepoRoot
$config = Get-HarnessConfig -RepoRoot $repoRoot

if (-not $config['gates.vulnerablePackages.fail']) {
    Write-Host 'Vulnerable-package gate disabled in harness.yml (gates.vulnerablePackages.fail: false).'
    exit 0
}

if ($null -eq $IncludeTransitive) {
    $IncludeTransitive = $config['gates.vulnerablePackages.includeTransitive']
}

# Severity ordering, lowest first. An unset -Severity means "anything counts".
$order = @{ 'low' = 0; 'moderate' = 1; 'high' = 2; 'critical' = 3 }
$floor = if ($Severity) { $order[$Severity.ToLowerInvariant()] } else { -1 }

$target = if ($config['solution']) { $config['solution'] } else { $repoRoot }

# Test seam: HARNESS_VULN_FIXTURE points at a canned `dotnet list package
# --vulnerable --format json` document, so CI can prove this gate's parsing and
# exit-code logic without committing a real CVE to a public repository. Only the
# fixture suite sets it; see fixtures/BadCode/README.md for the trade-off.
$fixture = $env:HARNESS_VULN_FIXTURE

if ($fixture) {
    if (-not (Test-Path -LiteralPath $fixture)) {
        Write-Host "GATE COULD NOT RUN: HARNESS_VULN_FIXTURE points at a missing file: $fixture" -ForegroundColor Red
        exit 1
    }
    Write-Host "Reading vulnerability report from fixture: $fixture"
    $raw = Get-Content -LiteralPath $fixture -Raw
    $exit = 0
}
else {
    $scanArgs = @('list', $target, 'package', '--vulnerable', '--format', 'json')
    if ($IncludeTransitive) { $scanArgs += '--include-transitive' }

    Write-Host "Scanning for vulnerable packages$(if ($IncludeTransitive) { ' (including transitive)' })..."

    $raw = & dotnet @scanArgs 2>&1
    $exit = $LASTEXITCODE
}

if ($exit -ne 0) {
    # A restore failure here means the gate could not run. That is not a pass.
    Write-Host 'GATE COULD NOT RUN: dotnet list package --vulnerable failed.' -ForegroundColor Red
    Write-Host ($raw | Out-String)
    Write-Host '  Fix: run `dotnet restore` first, and confirm the project has a NuGet source configured.'
    exit 1
}

# --format json arrived in .NET 9; fall back to text parsing on older SDKs.
$findings = @()
$json = $null
try { $json = $raw | Out-String | ConvertFrom-Json } catch { $json = $null }

if ($json -and $json.PSObject.Properties.Name -contains 'projects') {
    # A scan that enumerated no projects examined nothing, and "found no
    # advisories" would be a pass it did not earn. Clean projects DO appear here
    # - as {"path": ...} entries with no 'frameworks' key, which is exactly the
    # shape that used to crash the parser - so an empty array means enumeration
    # failed, not that everything was clean. Same remediation as a failed scan.
    if (@($json.projects).Count -eq 0) {
        Write-Host 'GATE COULD NOT RUN: the scan enumerated no projects.' -ForegroundColor Red
        Write-Host '  Fix: run `dotnet restore` first, and confirm the target contains projects'
        Write-Host "  and has a NuGet source configured. Target: $target"
        exit 1
    }

    foreach ($project in $json.projects) {
        # A project with no advisories is emitted as {"path": ...} with no
        # 'frameworks' key at all. Under Set-StrictMode, `$project.frameworks`
        # throws on the absent property rather than returning $null, so the
        # membership has to be tested before the value is read.
        $frameworks = $project.PSObject.Properties['frameworks']
        if (-not $frameworks) { continue }
        foreach ($fw in $frameworks.Value) {
            foreach ($listName in @('topLevelPackages', 'transitivePackages')) {
                $packages = $fw.PSObject.Properties[$listName]
                if (-not $packages) { continue }
                foreach ($pkg in $packages.Value) {
                    foreach ($vuln in @($pkg.vulnerabilities)) {
                        $findings += [PSCustomObject]@{
                            Project  = Split-Path $project.path -Leaf
                            Package  = $pkg.id
                            Version  = $pkg.resolvedVersion
                            Severity = $vuln.severity
                            Advisory = $vuln.advisoryurl
                        }
                    }
                }
            }
        }
    }
}
else {
    # Text fallback: "   > Package.Name   1.2.3   1.2.3   High   https://..."
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*>\s+(\S+)\s+(\S+)\s+(\S+)\s+(Low|Moderate|High|Critical)\s+(\S+)') {
            $findings += [PSCustomObject]@{
                Project  = ''
                Package  = $Matches[1]
                Version  = $Matches[3]
                Severity = $Matches[4]
                Advisory = $Matches[5]
            }
        }
    }
}

$blocking = @($findings | Where-Object {
        $rank = $order[("$($_.Severity)").ToLowerInvariant()]
        $null -eq $rank -or $rank -ge $floor
    })

if ($blocking.Count -eq 0) {
    Write-Host "PASS: no vulnerable packages$(if ($Severity) { " at or above $Severity" })." -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "FAIL: $($blocking.Count) vulnerable package reference(s)." -ForegroundColor Red
$blocking | Sort-Object Severity, Package | Format-Table -AutoSize Severity, Package, Version, Project, Advisory | Out-String | Write-Host

Write-Host 'Fix by upgrading to a patched version. If no patch exists, either replace the'
Write-Host 'dependency or record an explicit, time-boxed accept - do not silence this gate.'
exit 1
