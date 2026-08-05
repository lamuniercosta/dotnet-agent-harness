#!/usr/bin/env pwsh
<#
  Asserts each gate's exit code against the fixture in a given state.

    pwsh ./scripts/Assert-Gates.ps1 -Expect Fail    # broken fixture
    pwsh ./scripts/Assert-Gates.ps1 -Expect Pass    # after apply-fix.ps1

  Both directions are required. Only asserting Fail would let a gate that always
  fails pass CI; only asserting Pass would let a gate that never fires pass.

  -Expect Fail means "at least one gate must be red, and specifically the ones
  we planted violations for". It does NOT mean every gate is red - the fixture
  plants one violation per gate, so each is checked individually.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Fail', 'Pass')]
    [string]$Expect,

    [string]$Repo = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# The fixture is nested inside the harness's own git repository, so the gates'
# default repo-root discovery (git rev-parse --show-toplevel) would resolve to
# the HARNESS root and look for CodeMetricsConfig.txt there. Pin them to the
# fixture. Any monorepo package hits the same thing.
$env:HARNESS_REPO_ROOT = (Resolve-Path -LiteralPath $Repo).Path

$expectedExit = if ($Expect -eq 'Fail') { 1 } else { 0 }
$failures = 0
$checks = 0

function Assert-Gate {
    <#
      Exit contract: 0 = pass, 1 = fail, 2 = SKIPPED.

      Exit 2 is never accepted here. A skipped gate verified nothing, so it can
      satisfy neither -Expect Fail nor -Expect Pass - accepting it would let the
      fixture go green while a gate silently did no work, which is the exact
      failure this suite exists to catch.
    #>
    param([string]$Name, [string]$Script, [string[]]$GateArgs = @())

    $script:checks++
    $path = Join-Path $Repo "scripts/$Script"

    if (-not (Test-Path $path)) {
        Write-Host "  FAIL  $Name - gate script not installed at $path" -ForegroundColor Red
        $script:failures++
        return
    }

    # Captured rather than discarded: on failure the gate's own output is the
    # only thing that explains WHY, and a CI log that says "expected 0, got 1"
    # with no findings is undiagnosable. Printed only when something is wrong,
    # so a passing run stays a clean four-line table.
    $output = & pwsh -NoProfile -File $path @GateArgs 2>&1
    $actual = $LASTEXITCODE

    function Show-GateOutput {
        Write-Host '        --- gate output ---' -ForegroundColor DarkGray
        $output | Select-Object -Last 25 | ForEach-Object {
            Write-Host "        $_" -ForegroundColor DarkGray
        }
    }

    # "GATE NOT WIRED" also exits 1, which is exactly what -Expect Fail wants -
    # so a fixture whose analyzer config never installed would satisfy the RED
    # phase forever while verifying nothing. That is how a cross-platform bug
    # (dotfiles invisible to Get-ChildItem on Linux) sat behind a green RED
    # phase. Treat it as a failure in BOTH directions.
    if ($output -match 'GATE NOT WIRED') {
        Write-Host ("  FAIL  {0,-22} gate not wired - it refused to run, it did not check anything" -f $Name) -ForegroundColor Red
        Show-GateOutput
        $script:failures++
        return
    }

    if ($actual -eq 2) {
        Write-Host ("  FAIL  {0,-22} exit 2 (SKIPPED) - verified nothing" -f $Name) -ForegroundColor Red
        Show-GateOutput
        $script:failures++
        return
    }

    if ($actual -eq $expectedExit) {
        Write-Host ("  ok    {0,-22} exit {1} (expected {1})" -f $Name, $actual)
    }
    else {
        Write-Host ("  FAIL  {0,-22} exit {1}, expected {2}" -f $Name, $actual, $expectedExit) -ForegroundColor Red
        Show-GateOutput
        $script:failures++
    }
}

Write-Host ""
Write-Host "Fixture state: $Expect (every gate must exit $expectedExit)"
Write-Host ""

Assert-Gate 'analyzers'   'run-roslyn-analyzers.ps1'      @('-All')
Assert-Gate 'complexity'  'run-cyclomatic-complexity.ps1' @('-All')
Assert-Gate 'inspectcode' 'run-jetbrains-inspectcode.ps1' @('-All')

# The vulnerable-package gate is proven against a canned document rather than a
# real CVE - see the fixture README for why. Only meaningful in the Fail state:
# the stub always describes findings, so there is no Pass equivalent to assert.
if ($Expect -eq 'Fail') {
    $checks++
    $stub = Join-Path $Repo 'stub-vulnerable.json'
    $gate = Join-Path $Repo 'scripts/run-vulnerable-packages.ps1'

    if ((Test-Path $stub) -and (Test-Path $gate)) {
        $env:HARNESS_VULN_FIXTURE = $stub
        $gateOutput = & pwsh -NoProfile -File $gate 2>&1 | Out-String
        $actual = $LASTEXITCODE
        Remove-Item Env:\HARNESS_VULN_FIXTURE -ErrorAction SilentlyContinue

        # Exit code alone proves nothing here. A parse error mid-document also
        # exits 1, so "exit 1" cannot distinguish "found the advisories" from
        # "crashed before reading them" - the same trap as GATE NOT WIRED.
        # The stub describes exactly $expectedFindings advisories; assert the
        # count the gate actually reported.
        $expectedFindings = 2
        $reported = if ($gateOutput -match 'FAIL: (\d+) vulnerable package reference') { [int]$Matches[1] } else { -1 }

        if ($actual -eq 1 -and $reported -eq $expectedFindings) {
            Write-Host ("  ok    {0,-22} exit 1, parsed {1} stubbed advisories" -f 'vulnerable-packages', $reported)
        }
        elseif ($reported -lt 0) {
            Write-Host ("  FAIL  {0,-22} exit {1} but reported no finding count - the gate did not parse the stub" -f 'vulnerable-packages', $actual) -ForegroundColor Red
            Write-Host ($gateOutput -split "`r?`n" | Select-Object -First 5 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
            $failures++
        }
        else {
            Write-Host ("  FAIL  {0,-22} exit {1}, parsed {2} advisories, expected {3}" -f 'vulnerable-packages', $actual, $reported, $expectedFindings) -ForegroundColor Red
            $failures++
        }
    }
    else {
        Write-Host '  FAIL  vulnerable-packages   stub or gate script missing' -ForegroundColor Red
        $failures++
    }
}

# The property gate needs isolating.
#
# In the broken state the build fails (RS0030 on DateTime.Now is an error), so
# every test-based gate fails before its own assertion runs - proving nothing
# about the property gate specifically. So it is proven the other way round:
# from the FIXED, building state, break only Percentage.cs and confirm the gate
# catches the invariant violation, then restore.
if ($Expect -eq 'Pass') {
    $checks++
    $percentage = Join-Path $Repo 'Bad/Percentage.cs'
    $original = Get-Content -LiteralPath $percentage -Raw
    $gate = Join-Path $Repo 'scripts/run-property-tests.ps1'

    # Both runs are deliberately UNSCOPED, across the whole solution.
    #
    # This used to pass -Project Bad.Tests to work around #24: with
    # Bad.AcceptanceTests in the solution, that assembly reports "No test matches
    # the given testcase filter" for Category=Property, and the gate read the
    # whole run as SKIPPED even though Bad.Tests had run its property tests.
    #
    # Scoping it hid the bug from CI. Two test assemblies is the ordinary shape of
    # a .NET solution and the condition that reproduced #24, so the fixture runs
    # the gate the way a consumer does.
    try {
        # GREEN first, before anything is planted. Without it, an assertion that
        # only ever sees the broken state cannot tell a working gate from one that
        # fails on every multi-assembly solution.
        & dotnet build (Join-Path $Repo 'BadCode.sln') --verbosity quiet *> $null
        $cleanOutput = & pwsh -NoProfile -File $gate 2>&1 | Out-String
        $cleanExit = $LASTEXITCODE

        if ($cleanExit -eq 0 -and $cleanOutput -match 'passed \((\d+) test\(s\) executed') {
            Write-Host ("  ok    {0,-22} exit 0 on the intact solution, {1} executed" -f 'property-tests', $Matches[1])
        }
        else {
            Write-Host ("  FAIL  {0,-22} exit {1} on the intact solution - a gate that always fails proves nothing" -f 'property-tests', $cleanExit) -ForegroundColor Red
            Write-Host ($cleanOutput -split "`r?`n" | Select-Object -Last 6 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
            $failures++
        }

        # The SKIPPED direction, through the real script rather than the
        # classifier. Bad.AcceptanceTests has no Category=Property tests, so a
        # run scoped to it verifies nothing - which is exit 2, never 0.
        $checks++
        $skipOutput = & pwsh -NoProfile -File $gate -Project (Join-Path $Repo 'Bad.AcceptanceTests/Bad.AcceptanceTests.csproj') 2>&1 | Out-String
        $skipExit = $LASTEXITCODE

        if ($skipExit -eq 2 -and $skipOutput -match 'SKIPPED') {
            Write-Host ("  ok    {0,-22} exit 2 on a project with no property tests" -f 'property-tests')
        }
        else {
            Write-Host ("  FAIL  {0,-22} exit {1}, expected 2 - verifying nothing is not a pass" -f 'property-tests', $skipExit) -ForegroundColor Red
            Write-Host ($skipOutput -split "`r?`n" | Select-Object -Last 6 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
            $failures++
        }

        $checks++
        @'
namespace Bad;

// Temporarily broken by Assert-Gates to prove the property gate fires.
public static class Percentage
{
    public const decimal Min = 0m;
    public const decimal Max = 100m;

    public static decimal Clamp(decimal value) => value > Max ? Max : value;
}
'@ | Set-Content -LiteralPath $percentage -Encoding UTF8

        & dotnet build (Join-Path $Repo 'BadCode.sln') --verbosity quiet *> $null
        $brokenOutput = & pwsh -NoProfile -File $gate 2>&1 | Out-String
        $propExit = $LASTEXITCODE

        # Exit 1 alone is not proof. A build error, a missing filter match, a
        # crashed test host and a genuinely caught invariant all exit 1, so the
        # assertion names what it expects to find: the gate's own FAILED verdict
        # and the property that broke.
        $caught = $brokenOutput -match 'Property tests: FAILED' -and
                  $brokenOutput -match 'Clamp_AlwaysWithinBounds'

        if ($propExit -eq 1 -and $caught) {
            Write-Host ("  ok    {0,-22} exit 1 naming the violated invariant" -f 'property-tests')
        }
        else {
            Write-Host ("  FAIL  {0,-22} exit {1} - expected 1 reporting Clamp_AlwaysWithinBounds" -f 'property-tests', $propExit) -ForegroundColor Red
            Write-Host ($brokenOutput -split "`r?`n" | Select-Object -Last 8 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
            $failures++
        }
    }
    finally {
        Set-Content -LiteralPath $percentage -Value $original -Encoding UTF8 -NoNewline
        & dotnet build (Join-Path $Repo 'BadCode.sln') --verbosity quiet *> $null
    }
}

# The Gherkin mutation gate needs isolating for the same reason: in the broken
# state the build fails, so the gate dies at its own build step and proves
# nothing. Both directions are therefore proven from the FIXED state.
#
# Assert the FINDING, never the exit code alone: a crash, a build failure, a
# red baseline, and a real survivor all exit 1, and "passed (no survivors)"
# after executing zero tests is a pass the gate did not earn.
if ($Expect -eq 'Pass') {
    $gherkinGate = Join-Path $Repo 'scripts/run-gherkin-mutation.ps1'

    $checks++
    $killedOutput = & pwsh -NoProfile -File $gherkinGate 2>&1 | Out-String
    $killedExit = $LASTEXITCODE

    if ($killedExit -eq 0 -and $killedOutput -match 'passed \(no survivors\)') {
        Write-Host ("  ok    {0,-22} exit 0, no survivors against asserting bindings" -f 'gherkin-mutation')
    }
    else {
        Write-Host ("  FAIL  {0,-22} exit {1}, expected 0 with 'passed (no survivors)'" -f 'gherkin-mutation', $killedExit) -ForegroundColor Red
        Write-Host ($killedOutput -split "`r?`n" | Select-Object -Last 10 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
        $failures++
    }

    # The survivor direction: swap the asserting bindings for a catch-all that
    # matches the mutation sentinel and asserts nothing. Both scenarios then
    # still pass after mutation - the gate must report exactly 2 survivors.
    $checks++
    $steps = Join-Path $Repo 'Bad.AcceptanceTests/DiscountSteps.cs'
    $originalSteps = Get-Content -LiteralPath $steps -Raw

    @'
using Reqnroll;

namespace Bad.AcceptanceTests;

// Temporarily swapped in by Assert-Gates to prove the Gherkin mutation gate
// fires: catch-all bindings match the mutation sentinel and assert nothing,
// so every mutated scenario still passes and the mutant survives.
[Binding]
public sealed class DiscountSteps
{
    [Given("(.*)")]
    public void GivenAnything(string _) { }

    [When("(.*)")]
    public void WhenAnything(string _) { }

    [Then("(.*)")]
    public void ThenAnything(string _) { }
}
'@ | Set-Content -LiteralPath $steps -Encoding UTF8

    try {
        $survivorOutput = & pwsh -NoProfile -File $gherkinGate 2>&1 | Out-String
        $survivorExit = $LASTEXITCODE

        $reported = if ($survivorOutput -match 'FAILED - (\d+) survivor') { [int]$Matches[1] } else { -1 }

        if ($survivorExit -eq 1 -and $reported -eq 2) {
            Write-Host ("  ok    {0,-22} exit 1, reported {1} survivors against a catch-all binding" -f 'gherkin-mutation', $reported)
        }
        elseif ($reported -lt 0) {
            Write-Host ("  FAIL  {0,-22} exit {1} but reported no survivor count - cannot distinguish a survivor from a crash" -f 'gherkin-mutation', $survivorExit) -ForegroundColor Red
            Write-Host ($survivorOutput -split "`r?`n" | Select-Object -Last 10 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
            $failures++
        }
        else {
            Write-Host ("  FAIL  {0,-22} exit {1}, reported {2} survivors, expected exit 1 with 2" -f 'gherkin-mutation', $survivorExit, $reported) -ForegroundColor Red
            Write-Host ($survivorOutput -split "`r?`n" | Select-Object -Last 10 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
            $failures++
        }
    }
    finally {
        Set-Content -LiteralPath $steps -Value $originalSteps -Encoding UTF8 -NoNewline
        & dotnet build (Join-Path $Repo 'BadCode.sln') --verbosity quiet *> $null
    }
}

Write-Host ""
if ($failures -gt 0) {
    Write-Host "$failures of $checks gate assertions FAILED." -ForegroundColor Red
    Write-Host ""
    Write-Host 'A gate that did not fire on the broken fixture is not enforcing anything.'
    exit 1
}

Write-Host "All $checks gate assertions held." -ForegroundColor Green
exit 0
