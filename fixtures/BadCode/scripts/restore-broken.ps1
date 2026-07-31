#!/usr/bin/env pwsh
<#
  Rewrites the fixture back to its broken form - the inverse of apply-fix.ps1.

  The fixture owns BOTH states explicitly rather than relying on `git checkout`
  to undo the fix. Depending on git would mean the round trip only works from a
  clean, committed tree: fine in CI, useless locally the first time someone runs
  apply-fix.ps1 before committing.

  Verifying in both directions is the point. A gate that always fails would pass
  a red-only check; a gate that never fires would pass a green-only one.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$bad = Join-Path $root 'Bad'
$tests = Join-Path $root 'Bad.Tests'

# VIOLATION: complexity gate (CA1502) - ~24 branches against a ceiling of 15.
Set-Content -LiteralPath (Join-Path $bad 'TangledRouter.cs') -Encoding UTF8 -Value @'
namespace Bad;

// VIOLATION: cyclomatic complexity gate (CA1502).
// Route has ~24 independent branches, well over the default ceiling of 15.
// The fix is extraction, not a suppression - see scripts/apply-fix.ps1.
public static class TangledRouter
{
    public static string Route(int code, bool retry, bool urgent, string? region)
    {
        if (code < 0)
        {
            return "invalid";
        }

        if (code == 0)
        {
            return retry ? "retry-zero" : "zero";
        }

        if (code < 10)
        {
            if (urgent && retry)
            {
                return "urgent-retry-low";
            }

            if (urgent)
            {
                return "urgent-low";
            }

            return retry ? "retry-low" : "low";
        }

        if (code < 100)
        {
            if (region == "eu")
            {
                return urgent ? "eu-urgent" : "eu";
            }

            if (region == "us")
            {
                return urgent ? "us-urgent" : "us";
            }

            if (region == "apac")
            {
                return retry ? "apac-retry" : "apac";
            }

            return "mid";
        }

        if (code < 1000)
        {
            if (retry && urgent && region is not null)
            {
                return "high-all";
            }

            if (retry && urgent)
            {
                return "high-retry-urgent";
            }

            return retry ? "high-retry" : "high";
        }

        return urgent ? "overflow-urgent" : "overflow";
    }
}
'@

# VIOLATION: BannedSymbols.txt / RS0030, configured as an ERROR.
Set-Content -LiteralPath (Join-Path $bad 'Clock.cs') -Encoding UTF8 -Value @'
namespace Bad;

// VIOLATION: BannedSymbols.txt / RS0030 (configured as an ERROR).
// DateTime.Now is machine-local and makes every test that touches it
// non-deterministic. The fix is TimeProvider injection.
public static class Clock
{
    public static DateTime Stamp() => DateTime.Now;
}
'@

# VIOLATION: Roslyn analyzer gate - unused parameter, unread field, async void.
Set-Content -LiteralPath (Join-Path $bad 'Sloppy.cs') -Encoding UTF8 -Value @'
namespace Bad;

// VIOLATION: Roslyn analyzer gate.
//   CA1801/IDE0060 - unused parameter
//   IDE0052/CA1823 - unread private field
//   VSTHRD100      - async void
public sealed class Sloppy
{
    private readonly int _neverRead = 42;

    public int Add(int a, int b, int unusedFlag) => a + b;

    public async void FireAndForget()
    {
        await Task.Delay(1);
    }
}
'@

# VIOLATION: security analyzer gate (CA2100) - only fires because AnalysisMode=All.
Set-Content -LiteralPath (Join-Path $bad 'UserLookup.cs') -Encoding UTF8 -Value @'
using System.Data.Common;

namespace Bad;

// VIOLATION: security analyzer gate (CA2100).
// The command text is concatenated from a caller-supplied value. This family of
// rules is OFF under the default AnalysisMode - it fires only because the
// harness sets AnalysisMode=All, which is precisely what it is there for.
public sealed class UserLookup(DbConnection connection)
{
    public DbCommand ByName(string name)
    {
        var command = connection.CreateCommand();
        command.CommandText = "SELECT Id FROM Users WHERE Name = '" + name + "'";
        return command;
    }
}
'@

# VIOLATION: InspectCode duplication - the one thing Roslyn does not report.
Set-Content -LiteralPath (Join-Path $bad 'Duplicated.cs') -Encoding UTF8 -Value @'
namespace Bad;

// VIOLATION: InspectCode duplication.
// Two methods with an identical body - the only gate in the harness that
// reports duplication, and the reason InspectCode is not redundant with Roslyn.
public sealed class Duplicated
{
    public decimal NetForOrder(decimal gross, decimal taxRate, decimal shipping)
    {
        var tax = gross * taxRate;
        var subtotal = gross + tax;
        var withShipping = subtotal + shipping;
        return decimal.Round(withShipping, 2, MidpointRounding.AwayFromZero);
    }

    public decimal NetForInvoice(decimal gross, decimal taxRate, decimal shipping)
    {
        var tax = gross * taxRate;
        var subtotal = gross + tax;
        var withShipping = subtotal + shipping;
        return decimal.Round(withShipping, 2, MidpointRounding.AwayFromZero);
    }
}
'@

# VIOLATION: mutation gate - the boundary is unasserted, so the mutant survives.
Set-Content -LiteralPath (Join-Path $tests 'DiscountTests.cs') -Encoding UTF8 -Value @'
using Bad;
using Xunit;

namespace Bad.Tests;

// Deliberately INADEQUATE tests.
//
// Both cases sit well away from the threshold, so `total >= 100` and
// `total > 100` behave identically under them. Line coverage of Discount.Apply
// is 100%; the mutation gate still fails, because coverage measures which lines
// ran, not which behaviour was asserted.
public class DiscountTests
{
    [Fact]
    public void Apply_WellAboveThreshold_Discounts()
    {
        Assert.Equal(180m, Discount.Apply(200m));
    }

    [Fact]
    public void Apply_WellBelowThreshold_DoesNotDiscount()
    {
        Assert.Equal(50m, Discount.Apply(50m));
    }
}
'@


# Property gate: the missing lower bound.
Set-Content -LiteralPath (Join-Path $bad 'Percentage.cs') -Encoding UTF8 -Value @'
namespace Bad;

// VIOLATION: the property-test gate.
//
// Clamp is meant to constrain any input to 0..100. It handles the upper bound
// and forgets the lower one, so a negative input passes straight through.
//
// This is the shape of bug property tests exist for: every example a developer
// thinks to write (0, 50, 100, 150) passes, because you only find it by trying
// values you would not have chosen. FsCheck tries them.
public static class Percentage
{
    public const decimal Min = 0m;
    public const decimal Max = 100m;

    public static decimal Clamp(decimal value) => value > Max ? Max : value;
}
'@

Write-Output 'Fixture restored to its broken form. Every gate should now exit 1.'
