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
# and a caught violation both exit 1. InspectCode's finding direction is NOT
# covered here, because it needs `jb` restored; the fixture round trip proves it
# instead. Its process/report verdicts use a fake `dotnet` command below. The
# property gate's failure direction is likewise proven end to end by the fixture,
# since it needs a real multi-assembly solution.

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
    param(
        [string]$Repo,
        [string]$Script,
        [string[]]$GateArgs = @(),
        [switch]$NativeExitErrors
    )

    $env:HARNESS_REPO_ROOT = $Repo
    try {
        $gateScript = Join-Path $Repo "scripts/$Script"
        if ($NativeExitErrors) {
            # CI enables native-exit promotion on some PowerShell/platform
            # versions. Exercise process-result verdicts under that stricter
            # mode without changing unrelated gates' established test setup.
            $runner = Join-Path $Repo '.gate-exit-test-runner.ps1'
            if (-not (Test-Path -LiteralPath $runner)) {
                Set-Content -LiteralPath $runner -Encoding UTF8 -Value @(
                    '[CmdletBinding(PositionalBinding = $false)]'
                    'param('
                    '    [string]$GateScript,'
                    '    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GateArgs'
                    ')'
                    '$PSNativeCommandUseErrorActionPreference = $true'
                    '& $GateScript @GateArgs'
                    'exit $LASTEXITCODE'
                )
            }
            $out = & pwsh -NoProfile -File $runner -GateScript $gateScript @GateArgs 2>&1 | Out-String
        }
        else {
            $out = & pwsh -NoProfile -File $gateScript @GateArgs 2>&1 | Out-String
        }
        return [PSCustomObject]@{ Exit = $LASTEXITCODE; Output = $out }
    }
    finally {
        Remove-Item Env:\HARNESS_REPO_ROOT -ErrorAction SilentlyContinue
    }
}

# A portable fake `dotnet` command lets the installed InspectCode gate reach its
# post-process verdicts without restoring JetBrains tools or using the network.
# The gate still builds its real command line and removes any stale report first.
function New-InspectCodeDotnetShim {
    param([string]$Repo)

    $shimDir = Join-Path $Repo '.inspectcode-test-bin'
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null

    $shimScript = Join-Path $shimDir 'dotnet-shim.ps1'
    Set-Content -LiteralPath $shimScript -Encoding UTF8 -Value @(
        '[CmdletBinding(PositionalBinding = $false)]'
        'param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArgs)'
        ''
        "if (`$CommandArgs.Count -ge 2 -and `$CommandArgs[0] -eq 'tool' -and `$CommandArgs[1] -eq 'restore') { exit 0 }"
        "if (`$CommandArgs.Count -ge 2 -and `$CommandArgs[0] -eq 'jb' -and `$CommandArgs[1] -eq 'inspectcode') {"
        '    exit [int]$env:HARNESS_INSPECTCODE_TEST_EXIT'
        '}'
        'Write-Error "Unexpected fake dotnet arguments: $CommandArgs"'
        'exit 1'
    )

    if ($IsWindows) {
        Set-Content -LiteralPath (Join-Path $shimDir 'dotnet.cmd') -Encoding Ascii -Value @(
            '@echo off'
            'pwsh -NoProfile -File "%~dp0dotnet-shim.ps1" %*'
            'exit /b %ERRORLEVEL%'
        )
    }
    else {
        $unixShim = Join-Path $shimDir 'dotnet'
        Set-Content -LiteralPath $unixShim -Encoding UTF8 -Value @(
            '#!/bin/sh'
            'exec pwsh -NoProfile -File "$(dirname "$0")/dotnet-shim.ps1" "$@"'
        )
        & chmod +x $unixShim
    }

    return $shimDir
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

    # ── InspectCode process/report verdicts ──────────────────────────────────
    # Exercise the installed script end to end with a fake dotnet command. The
    # fake restores successfully, then returns the requested InspectCode exit
    # without writing a SARIF report.
    $shimDir = New-InspectCodeDotnetShim -Repo $repo
    $originalPath = $env:PATH
    $env:PATH = "$shimDir$([System.IO.Path]::PathSeparator)$originalPath"
    try {
        $env:HARNESS_INSPECTCODE_TEST_EXIT = '3'

        # Prove the platform wrapper preserves the controlled process exit
        # before relying on it to test the gate. The old Unix wrapper invoked a
        # nested PowerShell script and collapsed exit 3 to 0, so the gate quite
        # correctly reached its missing-report failure instead of the skip.
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            & dotnet jb inspectcode ignored.sln
            $shimExit = $LASTEXITCODE
        }
        finally {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
        Assert-That 'inspectcode test shim preserves native exit 3' `
            ($shimExit -eq 3) `
            "fake dotnet exited $shimExit - the gate verdict test would be exercising the wrong process result"

        $r = Invoke-Gate -Repo $repo -Script 'run-jetbrains-inspectcode.ps1' `
            -GateArgs @('-All', '-NoBuild') -NativeExitErrors

        Assert-That 'inspectcode: jb exit 3 is SKIPPED, not clean' `
            ($r.Exit -eq 2 -and $r.Output -match 'SKIPPED' -and $r.Output -match 'no matching files') `
            "exit $($r.Exit) - InspectCode matched nothing, so it did not earn a pass. Output: $($r.Output.Trim())"

        $env:HARNESS_INSPECTCODE_TEST_EXIT = '0'
        $r = Invoke-Gate -Repo $repo -Script 'run-jetbrains-inspectcode.ps1' `
            -GateArgs @('-All', '-NoBuild') -NativeExitErrors

        Assert-That 'inspectcode: a missing SARIF report fails closed' `
            ($r.Exit -eq 1 -and $r.Output -match 'GATE COULD NOT RUN' -and $r.Output -match 'no SARIF report') `
            "exit $($r.Exit) - a successful process without its promised report is inconclusive"
    }
    finally {
        $env:PATH = $originalPath
        Remove-Item Env:\HARNESS_INSPECTCODE_TEST_EXIT -ErrorAction SilentlyContinue
    }

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

    # The legacy `fail` key acts as this gate's enable switch. Turning it off
    # verifies nothing, so it follows the same disabled-gate contract as
    # InspectCode and property tests.
    $configPath = Join-Path $repo 'harness.yml'
    $config = Get-Content -LiteralPath $configPath -Raw
    $config = $config -replace '(?m)^    fail: true\s*$', '    fail: false'
    Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8

    $r = Invoke-Gate -Repo $repo -Script 'run-vulnerable-packages.ps1'
    Assert-That 'vulnerable-packages: disabled gate exits 2, not 0' `
        ($r.Exit -eq 2) `
        "exit $($r.Exit) - a disabled scan verified no dependencies"
    Assert-That 'vulnerable-packages: disabled gate says SKIPPED' `
        ($r.Output -match 'SKIPPED')

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
    # invocation and rejects a solution outright, so interleaved output never
    # reaches this function. The aggregation over several projects is proven end
    # to end by the fixture, which runs a real two-assembly solution.
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
        'a successful run that matched nothing verified nothing, which is exit 2'

    # One project is still several runs when it multi-targets. A no-match on one
    # framework beside a crashed host on another is the per-project version of
    # the interleaving bug, and per-project scheduling does not separate them -
    # only failing closed does.
    $multiTfm = @(
        'A total of 1 test files matched the specified pattern.'
        'No test matches the given testcase filter `Category=Property` in /r/Unit/net8.0/Unit.dll'
        'The active test run was aborted. Reason: Test host process crashed'
    )
    $outcome = Get-TestRunOutcome -Output $multiTfm -ExitCode 1
    Assert-That 'property verdict: a no-match on one framework does not excuse a crash on another' `
        ($outcome.Outcome -eq 'Inconclusive') `
        "got $($outcome.Outcome) - a failed process with nothing executed is never a skip"

    # Matched but every one skipped: the tests exist and are tagged, so telling
    # someone to add property tests they already have sends them the wrong way.
    # Single project, multi-targeted: matched on one framework and skipped there,
    # no match on the other. Interleaved two-assembly input would not reach this
    # function any more, so it is not used as a fixture for it.
    $matchedAllSkipped = @(
        'A total of 1 test files matched the specified pattern.'
        'No test matches the given testcase filter `Category=Property` in /r/Unit/net9.0/Unit.dll'
        'Passed!  - Failed:     0, Passed:     0, Skipped:     2, Total:     2, Duration: 3 ms - Unit.dll (net8.0)'
    )
    $outcome = Get-TestRunOutcome -Output $matchedAllSkipped -ExitCode 0
    Assert-That 'property verdict: all-skipped is distinguishable from none-tagged' `
        ($outcome.Outcome -eq 'NothingMatched' -and $outcome.Skipped -eq 2) `
        "got $($outcome.Outcome)/skipped=$($outcome.Skipped) - the remediation differs between the two"

    # ── Discovery returns an array, even for one project ─────────────────────
    # PowerShell unwraps a one-element array on return, and .Count on the
    # resulting string throws under Set-StrictMode - so a repo with exactly one
    # test project crashed before running anything. The fixture's two projects
    # hid it, which is why this asserts the single-project shape specifically.
    $solo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-solo-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $solo -Force | Out-Null
    $repos += $solo
    Set-Content -LiteralPath (Join-Path $solo 'Only.csproj') -Encoding UTF8 -Value @(
        '<Project Sdk="Microsoft.NET.Sdk">'
        '  <ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.0.0" /></ItemGroup>'
        '</Project>'
    )

    # Asserts the CALLER-SIDE contract: wrap the whole expression in @(). The
    # function returns plain, because @() around a comma-returned array nests it
    # instead of flattening - verified both ways round.
    Assert-That 'discovery: one project wraps to a one-element array' `
        (@(Get-TestProjects -RepoRoot $solo).Count -eq 1) `
        'a one-element return unwraps to a string, and .Count on it throws under StrictMode'

    Assert-That 'discovery: the wrapped result is paths, not a nested array' `
        ((@(Get-TestProjects -RepoRoot $solo))[0] -is [string]) `
        'a nested array here makes Split-Path emit every path at once and dotnet test choke'

    # Discovery is scoped to the solution, not the repo. An orphan test project
    # outside it - a tools/ or scratch/ one that fails to restore - would
    # otherwise fail this gate while the solution's own property tests were
    # green, which is the objection that makes -Project <solution> a rejection.
    Set-Content -LiteralPath (Join-Path $solo 'Only.sln') -Encoding UTF8 -Value @(
        'Microsoft Visual Studio Solution File, Format Version 12.00'
        'Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Only", "Only.csproj", "{11111111-1111-1111-1111-111111111111}"'
        'EndProject'
    )
    New-Item -ItemType Directory -Path (Join-Path $solo 'scratch') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $solo 'scratch/Orphan.csproj') -Encoding UTF8 -Value @(
        '<Project Sdk="Microsoft.NET.Sdk">'
        '  <ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.0.0" /></ItemGroup>'
        '</Project>'
    )

    $scoped = @(Get-TestProjects -RepoRoot $solo)
    Assert-That 'discovery: a test project outside the solution is not run' `
        ($scoped.Count -eq 1 -and $scoped[0] -notmatch 'Orphan') `
        "found $($scoped.Count): $($scoped -join ', ') - the solution is the authority on membership"

    # Two solutions: which one defines the tests is unknowable, and answering it
    # with a repo-wide sweep is how the orphan got back in. "No solution exists"
    # and "which solution is unclear" are different answers.
    Set-Content -LiteralPath (Join-Path $solo 'Second.sln') -Encoding UTF8 -Value @(
        'Microsoft Visual Studio Solution File, Format Version 12.00'
    )
    $threw = $false
    try { $null = Get-TestProjects -RepoRoot $solo } catch { $threw = $true }

    Assert-That 'discovery: an ambiguous solution set is refused, not swept' `
        $threw `
        'falling back to a repo-wide sweep here silently runs projects outside any solution'

    Remove-Item -LiteralPath (Join-Path $solo 'Second.sln') -Force

    # ── The gate script's own exits, not just the classifier ─────────────────
    # Everything above asserts Get-TestRunOutcome on canned strings. A regression
    # that classified correctly and then exited wrong in the aggregation block,
    # or restored the solution fallback, would stay green. These run the real
    # script; both paths return before any build, so no SDK is involved.
    $r = Invoke-Gate -Repo $repo -Script 'run-property-tests.ps1' -GateArgs @('-Project', 'BadCode.sln')
    Assert-That 'property gate: a solution passed to -Project is rejected' `
        ($r.Exit -eq 1 -and $r.Output -match 'single test \.csproj') `
        "exit $($r.Exit) - expanding it would run projects the caller never named"

    # A directory is the other way back into an interleaved run: Resolve-BuildTarget
    # accepts any path that exists, so `-Project tests` would become one dotnet
    # test spanning everything under it.
    $r = Invoke-Gate -Repo $repo -Script 'run-property-tests.ps1' -GateArgs @('-Project', '.')
    Assert-That 'property gate: a directory passed to -Project is rejected' `
        ($r.Exit -eq 1 -and $r.Output -match 'single test \.csproj') `
        "exit $($r.Exit) - a folder spans several projects, whose output cannot be told apart"

    # $repo holds Sample.csproj and Sloppy.cs but no test project, so discovery
    # finds nothing. It must say so rather than falling back to the solution -
    # that fallback is the interleaved path this design exists to avoid.
    $r = Invoke-Gate -Repo $repo -Script 'run-property-tests.ps1'
    Assert-That 'property gate: no discoverable test project fails loudly' `
        ($r.Exit -eq 1 -and $r.Output -match 'no test projects found') `
        "exit $($r.Exit) - a silent fallback to the whole solution is how the masking returns"

    # Last, because it changes what discovery sees in this repo. Two solutions
    # make scope unknowable, and the throw from discovery has to arrive as a gate
    # verdict with remediation rather than a raw PowerShell error.
    foreach ($s in 'One.sln', 'Two.sln') {
        Set-Content -LiteralPath (Join-Path $repo $s) -Encoding UTF8 `
            -Value 'Microsoft Visual Studio Solution File, Format Version 12.00'
    }
    $r = Invoke-Gate -Repo $repo -Script 'run-property-tests.ps1'

    # Asserts the remediation reaches the user, not just that something failed.
    # Config resolution refuses ambiguous solutions before discovery is even
    # reached, and that refusal used to arrive as a PowerShell stack trace.
    Assert-That 'property gate: ambiguous scope is a gate verdict, not a crash' `
        ($r.Exit -eq 1 -and $r.Output -match 'GATE COULD NOT RUN' -and $r.Output -match "Set 'solution:'") `
        "exit $($r.Exit) - the user needs the remediation, not a stack trace"
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
