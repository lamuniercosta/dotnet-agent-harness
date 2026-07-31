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

    & pwsh -NoProfile -File $path @GateArgs *> $null
    $actual = $LASTEXITCODE

    if ($actual -eq 2) {
        Write-Host ("  FAIL  {0,-22} exit 2 (SKIPPED) - verified nothing" -f $Name) -ForegroundColor Red
        $script:failures++
        return
    }

    if ($actual -eq $expectedExit) {
        Write-Host ("  ok    {0,-22} exit {1} (expected {1})" -f $Name, $actual)
    }
    else {
        Write-Host ("  FAIL  {0,-22} exit {1}, expected {2}" -f $Name, $actual, $expectedExit) -ForegroundColor Red
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
        & pwsh -NoProfile -File $gate *> $null
        $actual = $LASTEXITCODE
        Remove-Item Env:\HARNESS_VULN_FIXTURE -ErrorAction SilentlyContinue

        if ($actual -eq 1) {
            Write-Host ("  ok    {0,-22} exit 1 (parsed the stubbed advisories)" -f 'vulnerable-packages')
        }
        else {
            Write-Host ("  FAIL  {0,-22} exit {1}, expected 1" -f 'vulnerable-packages', $actual) -ForegroundColor Red
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

    try {
        & dotnet build (Join-Path $Repo 'BadCode.sln') --verbosity quiet *> $null
        & pwsh -NoProfile -File (Join-Path $Repo 'scripts/run-property-tests.ps1') *> $null
        $propExit = $LASTEXITCODE

        if ($propExit -eq 1) {
            Write-Host ("  ok    {0,-22} exit 1 on a violated invariant" -f 'property-tests')
        }
        else {
            Write-Host ("  FAIL  {0,-22} exit {1}, expected 1 - the gate missed a broken invariant" -f 'property-tests', $propExit) -ForegroundColor Red
            $failures++
        }
    }
    finally {
        Set-Content -LiteralPath $percentage -Value $original -Encoding UTF8 -NoNewline
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
