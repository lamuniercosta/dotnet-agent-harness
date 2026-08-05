#!/usr/bin/env pwsh
# Proves the gates honour the exit contract: 0 = pass, 1 = fail, 2 = SKIPPED.
#
# The contract is the harness's load-bearing property, and it has regressed
# before: run-property-tests.ps1 once exited 0 with zero property tests, and the
# three diff-scoped gates once exited 0 on an empty changed-file set. Both
# reported a pass over something they had never read.
#
# A gate that always skips looks exactly like a gate that correctly skips, so the
# SKIPPED assertions are paired with cases that must still fail.
#
# Roslyn and complexity get a real planted violation here, and each asserts the
# diagnostic it expects to see rather than accepting any exit 1 - a build error
# and a caught violation both exit 1. InspectCode's failure direction is NOT
# covered here, because it needs `jb` restored; the fixture round trip proves it
# instead. The property gate's failure direction is likewise proven end to end by
# the fixture, since it needs a real multi-assembly solution.

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

    # Names the diagnostic rather than accepting any exit 1: a build error, an
    # unwired gate and a caught violation all exit 1, so a bare exit check would
    # pass while the analyzer found nothing.
    Assert-That 'analyzers: a changed file with a violation still exits 1' `
        ($r.Exit -eq 1 -and $r.Output -match 'Sloppy\.cs' -and $r.Output -match '\b(CA|IDE)\d+\b') `
        "exit $($r.Exit) - expected 1 reporting a CA/IDE diagnostic in Sloppy.cs"

    # Complexity gets its own planted violation. Without it, a change that made
    # every gate skip would still pass the block above on Roslyn alone.
    $complex = @('namespace Sample;', '', 'public static class Tangled', '{', '    public static int Route(int n)', '    {')
    foreach ($i in 1..20) { $complex += "        if (n == $i) { return $i; }" }
    $complex += @('        return 0;', '    }', '}')
    Set-Content -LiteralPath (Join-Path $repo 'Tangled.cs') -Value $complex -Encoding UTF8
    $r = Invoke-Gate -Repo $repo -Script 'run-cyclomatic-complexity.ps1'

    Assert-That 'complexity: a changed file over the threshold still exits 1' `
        ($r.Exit -eq 1 -and $r.Output -match 'Route') `
        "exit $($r.Exit) - expected 1 naming the method over the threshold"

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
    # Canned single-project output. #24 itself - one assembly's no-match masking
    # another's passing tests - is now prevented structurally rather than parsed
    # around, and is proven end to end by the fixture's two-assembly solution.
    $ranClean = @(
        'A total of 1 test files matched the specified pattern.'
        'Passed!  - Failed:     0, Passed:     2, Skipped:     0, Total:     2, Duration: 59 ms - Unit.dll (net8.0)'
    )
    $outcome = Get-TestRunOutcome -Output $ranClean
    Assert-That 'property verdict: executed tests are counted, skipped ones are not' `
        ($outcome.Outcome -eq 'Ran' -and $outcome.Executed -eq 2) `
        "got $($outcome.Outcome)/$($outcome.Executed)"

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

    # Total counts skipped tests. A suite where every property test carries
    # [Fact(Skip = "...")] would otherwise report "2 tests executed" having run
    # no test body - the same vacuous pass this gate exists to prevent.
    # Asserts the exact outcome, not merely "not Ran": Unknown is also not Ran,
    # and Unknown exits 1. A single-assembly suite whose property tests are all
    # skipped emits no no-match line at all, so classifying it by that line alone
    # made it Unknown and failed a repo that should have been SKIPPED.
    $allSkipped = @(
        'A total of 1 test files matched the specified pattern.'
        'Passed!  - Failed:     0, Passed:     0, Skipped:     2, Total:     2, Duration: 3 ms - Unit.dll (net8.0)'
    )
    $outcome = Get-TestRunOutcome -Output $allSkipped -ExitCode 0
    Assert-That 'property verdict: all-skipped with no no-match line is SKIPPED, not a failure' `
        ($outcome.Outcome -eq 'NothingMatched' -and $outcome.Skipped -eq 2) `
        "got $($outcome.Outcome)/skipped=$($outcome.Skipped) - nothing verified is exit 2, and Unknown would exit 1"

    # Older VSTest spreads the counts across lines under a "Total tests:" heading.
    # Matching only "Total:" misses it entirely, turning a healthy run into
    # Unknown and a healthy repo into exit 1.
    $legacyFormat = @(
        'Total tests: 3'
        '     Passed: 3'
        ' Test Run Successful.'
    )
    $outcome = Get-TestRunOutcome -Output $legacyFormat
    Assert-That 'property verdict: legacy VSTest summary is still read as a real run' `
        ($outcome.Outcome -eq 'Ran' -and $outcome.Executed -eq 3) `
        "got $($outcome.Outcome)/$($outcome.Executed) - a valid run must not be reported as unreadable"

    # A no-match line accounts for one assembly, not for a failed run. With two
    # assemblies - one with no matching tests, one crashing before it reports any
    # counts - the output is indistinguishable from a clean skip except for the
    # exit code. Folding that into NothingMatched reports SKIPPED over a failure.
    # A project that died before reporting anything: no counts, no no-match line,
    # non-zero exit. Nothing explains the absent tests, so the gate must say so
    # rather than call it a skip.
    #
    # The multi-assembly version of this - one project no-matching while another
    # crashes - is no longer expressible: the gate runs one project per
    # invocation and expands a solution into its projects, so interleaved output
    # never reaches this function. That aggregation is proven end to end by the
    # fixture, which runs a real two-assembly solution.
    $crashedProject = @(
        'A total of 1 test files matched the specified pattern.'
        'The active test run was aborted. Reason: Test host process crashed'
    )
    $outcome = Get-TestRunOutcome -Output $crashedProject -ExitCode 1
    Assert-That 'property verdict: a project that died before reporting is Inconclusive' `
        ($outcome.Outcome -eq 'Inconclusive') `
        "got $($outcome.Outcome) - a crashed run must not be reported as nothing to verify"

    $outcome = Get-TestRunOutcome -Output $noneMatched -ExitCode 0
    Assert-That 'property verdict: a clean no-match run is still SKIPPED' `
        ($outcome.Outcome -eq 'NothingMatched') `
        'gating on the exit code must not turn a genuine skip into a failure'

    # Some runner versions exit non-zero when a filter matches nothing. Every
    # assembly attempted reported no match, so there was genuinely nothing to
    # run - deciding on the exit code alone would turn those empty runs into
    # failures, which is the accommodation the pre-PR gate made deliberately.
    $allNoMatchNonZero = @(
        'A total of 1 test files matched the specified pattern.'
        'A total of 1 test files matched the specified pattern.'
        'No test matches the given testcase filter `Category=Property` in /r/Unit.dll'
        'No test matches the given testcase filter `Category=Property` in /r/Acceptance.dll'
    )
    $outcome = Get-TestRunOutcome -Output $allNoMatchNonZero -ExitCode 1
    Assert-That 'property verdict: every assembly no-matching is SKIPPED even on a non-zero exit' `
        ($outcome.Outcome -eq 'NothingMatched') `
        "got $($outcome.Outcome) - a runner that exits non-zero on an empty filter must not fail the gate"

    # Matched but every one skipped: the tests exist and are tagged, so telling
    # someone to add property tests they already have sends them the wrong way.
    $matchedAllSkipped = @(
        'No test matches the given testcase filter `Category=Property` in /r/Acceptance.dll'
        'Passed!  - Failed:     0, Passed:     0, Skipped:     2, Total:     2, Duration: 3 ms - Unit.dll (net8.0)'
    )
    $outcome = Get-TestRunOutcome -Output $matchedAllSkipped -ExitCode 0
    Assert-That 'property verdict: all-skipped is distinguishable from none-tagged' `
        ($outcome.Outcome -eq 'NothingMatched' -and $outcome.Skipped -eq 2) `
        "got $($outcome.Outcome)/skipped=$($outcome.Skipped) - the remediation differs between the two"
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
