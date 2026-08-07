#!/usr/bin/env pwsh
# Self-test for Resolve-Solution: the single policy that decides which solution
# a command operates on. Covers the full decision matrix in throwaway temp dirs.
#
#   pwsh ./packs/dotnet/scripts/Test-SolutionResolver.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

$failures = 0
$checks = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $script:checks++
    if ($Expected -eq $Actual) {
        Write-Host "  ok    $Name"
    }
    else {
        Write-Host "  FAIL  $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red
        $script:failures++
    }
}

function Assert-Null {
    param([string]$Name, $Actual)
    $script:checks++
    if ($null -eq $Actual) {
        Write-Host "  ok    $Name"
    }
    else {
        Write-Host "  FAIL  $Name - expected null, got '$Actual'" -ForegroundColor Red
        $script:failures++
    }
}

function Assert-Throws {
    param([string]$Name, [scriptblock]$Block, [string]$Fragment)
    $script:checks++
    try {
        & $Block | Out-Null
        Write-Host "  FAIL  $Name - expected an error, got none" -ForegroundColor Red
        $script:failures++
    }
    catch {
        $msg = $_.Exception.Message
        if ($Fragment -and $msg -notmatch [regex]::Escape($Fragment)) {
            Write-Host "  FAIL  $Name - threw, but message lacks '$Fragment': $msg" -ForegroundColor Red
            $script:failures++
        }
        else {
            Write-Host "  ok    $Name"
        }
    }
}

$repos = [System.Collections.ArrayList]::new()

function New-TempRepo {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("sln-resolver-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    [void]$script:repos.Add($path)
    return $path
}

try {
    # ── Explicit -Explicit always wins ─────────────────────────────────────
    Write-Host 'Explicit parameter:'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'App.sln') -Value 'sln'
    Set-Content -LiteralPath (Join-Path $repo 'Other.sln') -Value 'sln'

    Assert-Equal 'explicit path wins over ambiguous candidates' `
        (Join-Path $repo 'App.sln') `
        (Resolve-Solution -RepoRoot $repo -Explicit 'App.sln')

    Assert-Throws 'explicit path that does not exist throws' `
        { Resolve-Solution -RepoRoot $repo -Explicit 'Missing.sln' } `
        'not found'

    # ── Declared solution: in harness.yml ──────────────────────────────────
    Write-Host 'Declared solution (harness.yml):'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'App.sln') -Value 'sln'
    Set-Content -LiteralPath (Join-Path $repo 'Other.sln') -Value 'sln'
    Set-Content -LiteralPath (Join-Path $repo 'harness.yml') -Encoding UTF8 -Value 'solution: App.sln'

    # Clear the config cache so the new harness.yml is read.
    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }

    Assert-Equal 'harness.yml solution: wins over ambiguous candidates' `
        (Join-Path $repo 'App.sln') `
        (Resolve-Solution -RepoRoot $repo)

    # ── Declared solution: missing file ────────────────────────────────────
    Write-Host 'Declared solution that does not exist:'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'harness.yml') -Encoding UTF8 -Value 'solution: Gone.sln'
    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }

    Assert-Throws 'harness.yml naming a missing solution throws' `
        { Resolve-Solution -RepoRoot $repo } `
        'does not exist'

    # ── Sole candidate ─────────────────────────────────────────────────────
    Write-Host 'Sole candidate:'
    $repo = New-TempRepo
    New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'src/App.sln') -Value 'sln'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    Assert-Equal 'one candidate anywhere wins' `
        (Join-Path $repo 'src/App.sln') `
        (Resolve-Solution -RepoRoot $repo)

    # ── Unique repo-root candidate ─────────────────────────────────────────
    Write-Host 'Unique root candidate (the issue repro):'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'App.sln') -Value 'sln'
    New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'tools/Other.sln') -Value 'sln'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    Assert-Equal 'root solution wins over nested tool solution' `
        (Join-Path $repo 'App.sln') `
        (Resolve-Solution -RepoRoot $repo)

    # ── Two at repo root ───────────────────────────────────────────────────
    Write-Host 'Two solutions at repo root:'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'One.sln') -Value 'sln'
    Set-Content -LiteralPath (Join-Path $repo 'Two.sln') -Value 'sln'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    Assert-Throws 'two at root throws' `
        { Resolve-Solution -RepoRoot $repo } `
        "Set 'solution:'"

    # ── Two nested, no root ────────────────────────────────────────────────
    Write-Host 'Two nested, no root:'
    $repo = New-TempRepo
    New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'src/App.sln') -Value 'sln'
    Set-Content -LiteralPath (Join-Path $repo 'tools/Other.sln') -Value 'sln'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    Assert-Throws 'two nested with no root throws' `
        { Resolve-Solution -RepoRoot $repo } `
        "Set 'solution:'"

    # ── Same-basename .sln/.slnx pair at root ──────────────────────────────
    Write-Host 'Same-basename .sln/.slnx pair at root:'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'App.sln') -Value 'sln'
    Set-Content -LiteralPath (Join-Path $repo 'App.slnx') -Value 'slnx'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    Assert-Throws 'sln/slnx pair at root throws' `
        { Resolve-Solution -RepoRoot $repo } `
        "Set 'solution:'"

    # ── No solution at all ─────────────────────────────────────────────────
    Write-Host 'No solution:'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'App.csproj') -Value 'proj'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    Assert-Null 'no solution returns null' `
        (Resolve-Solution -RepoRoot $repo)

    # ── Decoy under artifacts/ is excluded ─────────────────────────────────
    Write-Host 'Decoy under artifacts/:'
    $repo = New-TempRepo
    Set-Content -LiteralPath (Join-Path $repo 'App.sln') -Value 'sln'
    New-Item -ItemType Directory -Path (Join-Path $repo 'artifacts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'artifacts/Stale.sln') -Value 'sln'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    Assert-Equal 'artifacts/ decoy is excluded' `
        (Join-Path $repo 'App.sln') `
        (Resolve-Solution -RepoRoot $repo)

    # ── Refusal messages list candidates ───────────────────────────────────
    Write-Host 'Refusal messages:'
    $repo = New-TempRepo
    New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'src/A.sln') -Value 'sln'
    Set-Content -LiteralPath (Join-Path $repo 'tools/B.sln') -Value 'sln'

    if (Test-Path variable:script:HarnessConfigCache) { Remove-Variable -Scope script -Name HarnessConfigCache }
    $threw = $false; $msg = ''
    try { Resolve-Solution -RepoRoot $repo | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
    $script:checks++
    if ($threw -and $msg -match 'A\.sln' -and $msg -match 'B\.sln') {
        Write-Host "  ok    refusal lists both candidates"
    }
    else {
        Write-Host "  FAIL  refusal lists both candidates - threw=$threw msg=$msg" -ForegroundColor Red
        $script:failures++
    }
}
finally {
    foreach ($r in $repos) {
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "All $checks checks passed."
exit 0
