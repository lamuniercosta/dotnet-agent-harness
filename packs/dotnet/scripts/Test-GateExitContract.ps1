#!/usr/bin/env pwsh
# Proves the gates honour the exit contract: 0 = pass, 1 = fail, 2 = SKIPPED.
#
# The contract is the harness's load-bearing property, and it has regressed
# before: run-property-tests.ps1 once exited 0 with zero property tests, and the
# three diff-scoped gates once exited 0 on an empty changed-file set. Both
# reported a pass over something they had never read.
#
# Asserted in BOTH directions throughout. A gate that always skips looks exactly
# like a gate that correctly skips, so every SKIPPED assertion is paired with a
# case that must still fail.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$harnessRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$installer = Join-Path $harnessRoot 'install.ps1'
. (Join-Path $PSScriptRoot '_gate-common.ps1')

$checks = 0
$failures = 0

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')

    $script:checks++
    if ($Condition) {
        Write-Host ("  ok    {0}" -f $Name)
    }
    else {
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkGray }
        $script:failures++
    }
}

# A git repo with the harness installed and a clean tree.
#
# git is not optional here. Resolve-AnalysisScope widens to the whole solution
# when the target is not a git repository, which bypasses the empty-set branch
# entirely - the assertions below would never reach the code under test and
# would pass for the wrong reason.
function New-CleanRepo {
    param([string]$SourceFile)

    $repo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-exit-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $repo 'Sample.csproj') -Encoding UTF8 -Value @(
        '<Project Sdk="Microsoft.NET.Sdk">'
        '  <PropertyGroup>'
        '    <TargetFramework>net8.0</TargetFramework>'
        '    <Nullable>enable</Nullable>'
        '  </PropertyGroup>'
        '</Project>'
    )
    Set-Content -LiteralPath (Join-Path $repo 'Sample.cs') -Encoding UTF8 -Value $SourceFile

    & pwsh -NoProfile -File $installer $repo *>&1 | Out-Null

    Push-Location $repo
    try {
        # Explicit identity: CI runners have no global git config, and a commit
        # that fails leaves a dirty tree, which is the opposite of the state
        # these assertions need.
        & git init --quiet 2>&1 | Out-Null
        & git add -A 2>&1 | Out-Null
        & git -c user.email=test@example.invalid -c user.name=harness commit --quiet -m baseline 2>&1 | Out-Null
    }
    finally {
        Pop-Location
    }
    return $repo
}

function Invoke-Gate {
    param([string]$Repo, [string]$Script, [string[]]$GateArgs = @())

    $env:HARNESS_REPO_ROOT = $Repo
    try {
        $out = & pwsh -NoProfile -File (Join-Path $Repo "scripts/$Script") @GateArgs 2>&1 | Out-String
        return [PSCustomObject]@{ Exit = $LASTEXITCODE; Output = $out }
    }
    finally {
        Remove-Item Env:\HARNESS_REPO_ROOT -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Gate exit contract: 0 = pass, 1 = fail, 2 = SKIPPED'
Write-Host ''

$repos = @()
$cleanSource = @(
    'namespace Sample;'
    ''
    'public static class Calculator'
    '{'
    '    public static int Double(int value) => value * 2;'
    '}'
)

try {
    # ── Nothing changed → SKIPPED, never a pass ──────────────────────────────
    $repo = New-CleanRepo -SourceFile $cleanSource
    $repos += $repo

    foreach ($gate in @(
            @{ Script = 'run-roslyn-analyzers.ps1'; Name = 'analyzers' },
            @{ Script = 'run-cyclomatic-complexity.ps1'; Name = 'complexity' },
            @{ Script = 'run-jetbrains-inspectcode.ps1'; Name = 'inspectcode' }
        )) {
        $r = Invoke-Gate -Repo $repo -Script $gate.Script

        Assert-That "$($gate.Name): empty changed-file set exits 2, not 0" `
            ($r.Exit -eq 2) `
            "exit $($r.Exit) - a gate that read no files has not passed"
        Assert-That "$($gate.Name): says SKIPPED rather than implying clean" `
            ($r.Output -match 'SKIPPED')
    }

    # ── A real violation still fails ─────────────────────────────────────────
    # Without this, a change that made every gate exit 2 would pass the block
    # above. Roslyn only: it needs the SDK but not the jb tool.
    $violating = @(
        'namespace Sample;'
        ''
        'public static class Sloppy'
        '{'
        '    private static readonly string Unused = "never read";'
        ''
        '    public static int Double(int value) => value * 2;'
        '}'
    )
    Set-Content -LiteralPath (Join-Path $repo 'Sloppy.cs') -Value $violating -Encoding UTF8
    $r = Invoke-Gate -Repo $repo -Script 'run-roslyn-analyzers.ps1'

    Assert-That 'analyzers: a changed file with a violation still exits 1' `
        ($r.Exit -eq 1) `
        "exit $($r.Exit) - if everything skips, the gate verifies nothing"

    # ── Vulnerable packages: a scan that enumerated nothing is not clean ──────
    # Uses the canned-document seam, so no restore and no network.
    $emptyScan = Join-Path $repo 'empty-scan.json'
    Set-Content -LiteralPath $emptyScan -Encoding UTF8 -Value '{ "version": 1, "parameters": "--vulnerable", "projects": [] }'

    $env:HARNESS_VULN_FIXTURE = $emptyScan
    $r = Invoke-Gate -Repo $repo -Script 'run-vulnerable-packages.ps1'
    Remove-Item Env:\HARNESS_VULN_FIXTURE -ErrorAction SilentlyContinue

    Assert-That 'vulnerable-packages: a scan with no projects exits 1, not 0' `
        ($r.Exit -eq 1) `
        'reporting "no vulnerable packages" after enumerating nothing is a pass it did not earn'
    Assert-That 'vulnerable-packages: says it could not run' `
        ($r.Output -match 'GATE COULD NOT RUN')

    # ── Property-gate verdict (#24) ──────────────────────────────────────────
    # Canned output, because the case that matters needs two test assemblies and
    # the rule itself is what regressed. Real multi-assembly behaviour is proven
    # by the fixture round trip.
    $multiAssembly = @(
        'No test matches the given testcase filter `Category=Property` in /r/Acceptance.dll'
        'Passed!  - Failed:     0, Passed:     2, Skipped:     0, Total:     2, Duration: 59 ms - Unit.dll (net8.0)'
    )
    $outcome = Get-TestRunOutcome -Output $multiAssembly
    Assert-That 'property verdict: one assembly no-matching does not mask another running' `
        ($outcome.Outcome -eq 'Ran' -and $outcome.Executed -eq 2) `
        "got $($outcome.Outcome)/$($outcome.Executed) - this is #24: SKIPPED over a run that verified plenty"

    $noneMatched = @(
        'A total of 1 test files matched the specified pattern.'
        'No test matches the given testcase filter `Category=Property` in /r/Unit.dll'
    )
    $outcome = Get-TestRunOutcome -Output $noneMatched
    Assert-That 'property verdict: genuinely no property tests is still NothingMatched' `
        ($outcome.Outcome -eq 'NothingMatched') `
        'the single-assembly skip must survive the multi-assembly fix'

    $unreadable = @('Build succeeded.', 'Something entirely unexpected.')
    $outcome = Get-TestRunOutcome -Output $unreadable
    Assert-That 'property verdict: no count and no reason is Unknown, not a guess' `
        ($outcome.Outcome -eq 'Unknown') `
        'a run with no readable result must fail loudly rather than pass or skip'

    $zeroTotal = @('Passed!  - Failed:     0, Passed:     0, Skipped:     0, Total:     0, Duration: 1 ms - Unit.dll (net8.0)')
    $outcome = Get-TestRunOutcome -Output $zeroTotal
    Assert-That 'property verdict: a summary reporting zero tests is not a pass' `
        ($outcome.Outcome -ne 'Ran') `
        'Total: 0 means nothing executed, whatever the exit code said'
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
