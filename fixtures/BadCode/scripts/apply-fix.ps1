#!/usr/bin/env pwsh
<#
  Rewrites the fixture into its clean form.

  The fixture is verified in BOTH directions. Asserting only the red state
  would let a gate that always fails pass CI; asserting only green would let a
  gate that never fires pass. A gate must fire on bad code AND stay quiet on
  good code - one that cries wolf gets switched off, which is a slower way of
  not having it.

  Each fix below is the fix a developer would actually make: extraction rather
  than suppression, injection rather than a static call, a real assertion rather
  than a threshold change.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$bad = Join-Path $root 'Bad'
$tests = Join-Path $root 'Bad.Tests'

# 1. Complexity: extract the branches into focused helpers.
Set-Content -LiteralPath (Join-Path $bad 'TangledRouter.cs') -Encoding UTF8 -Value @'
namespace Bad;

// FIXED: each band is its own small method, so no single method exceeds the
// complexity ceiling. Extraction, not #pragma warning disable.
public static class TangledRouter
{
    public static string Route(int code, bool retry, bool urgent, string? region) => code switch
    {
        < 0 => "invalid",
        0 => retry ? "retry-zero" : "zero",
        < 10 => Low(retry, urgent),
        < 100 => Mid(retry, urgent, region),
        < 1000 => High(retry, urgent, region),
        _ => urgent ? "overflow-urgent" : "overflow",
    };

    private static string Low(bool retry, bool urgent) => (urgent, retry) switch
    {
        (true, true) => "urgent-retry-low",
        (true, false) => "urgent-low",
        (false, true) => "retry-low",
        _ => "low",
    };

    private static string Mid(bool retry, bool urgent, string? region) => region switch
    {
        "eu" => urgent ? "eu-urgent" : "eu",
        "us" => urgent ? "us-urgent" : "us",
        "apac" => retry ? "apac-retry" : "apac",
        _ => "mid",
    };

    private static string High(bool retry, bool urgent, string? region)
    {
        if (retry && urgent)
        {
            return region is not null ? "high-all" : "high-retry-urgent";
        }

        return retry ? "high-retry" : "high";
    }
}
'@

# 2. Banned symbol: inject TimeProvider instead of reading the machine clock.
Set-Content -LiteralPath (Join-Path $bad 'Clock.cs') -Encoding UTF8 -Value @'
namespace Bad;

// FIXED: time is injected, so tests can control it and the value is UTC.
public sealed class Clock(TimeProvider timeProvider)
{
    public DateTimeOffset Stamp() => timeProvider.GetUtcNow();
}
'@

# 3. Analyzer findings: drop the unused parameter and field, make async void a Task.
Set-Content -LiteralPath (Join-Path $bad 'Sloppy.cs') -Encoding UTF8 -Value @'
namespace Bad;

// FIXED: no unused parameter, no unread field, and the async method returns a
// Task so its failures are observable rather than crashing the process.
//
// static because neither method touches instance state - CA1822 is enabled by
// the harness's .editorconfig, so the "clean" state has to actually clear the
// same bar it asks of consumers.
public static class Sloppy
{
    public static int Add(int a, int b) => a + b;

    public static async Task CompleteAsync(CancellationToken cancellationToken = default)
    {
        await Task.Delay(1, cancellationToken);
    }
}
'@

# 4. Security: parameterise the query.
Set-Content -LiteralPath (Join-Path $bad 'UserLookup.cs') -Encoding UTF8 -Value @'
using System.Data.Common;

namespace Bad;

// FIXED: the caller-supplied value travels as a parameter, never as command text.
public sealed class UserLookup(DbConnection connection)
{
    public DbCommand ByName(string name)
    {
        var command = connection.CreateCommand();
        command.CommandText = "SELECT Id FROM Users WHERE Name = @name";

        var parameter = command.CreateParameter();
        parameter.ParameterName = "@name";
        parameter.Value = name;
        command.Parameters.Add(parameter);

        return command;
    }
}
'@

# 5. Duplication: one implementation, two names.
Set-Content -LiteralPath (Join-Path $bad 'Duplicated.cs') -Encoding UTF8 -Value @'
namespace Bad;

// FIXED: the shared calculation exists once. static because nothing here
// touches instance state (CA1822).
public static class Duplicated
{
    public static decimal NetForOrder(decimal gross, decimal taxRate, decimal shipping) =>
        Net(gross, taxRate, shipping);

    public static decimal NetForInvoice(decimal gross, decimal taxRate, decimal shipping) =>
        Net(gross, taxRate, shipping);

    private static decimal Net(decimal gross, decimal taxRate, decimal shipping)
    {
        var withShipping = gross + (gross * taxRate) + shipping;
        return decimal.Round(withShipping, 2, MidpointRounding.AwayFromZero);
    }
}
'@

# 6. Property gate: add the missing lower bound.
Set-Content -LiteralPath (Join-Path $bad 'Percentage.cs') -Encoding UTF8 -Value @'
namespace Bad;

// FIXED: both bounds are enforced, so Clamp always returns a value in 0..100.
public static class Percentage
{
    public const decimal Min = 0m;
    public const decimal Max = 100m;

    public static decimal Clamp(decimal value) => Math.Clamp(value, Min, Max);
}
'@

# 7. Mutation: assert the boundary. Discount.cs is UNCHANGED - the production
#    code was always correct; the test was inadequate. Fixing the test is the
#    whole point, and lowering the threshold would have hidden it.
Set-Content -LiteralPath (Join-Path $tests 'DiscountTests.cs') -Encoding UTF8 -Value @'
using Xunit;

namespace Bad.Tests;

// No `using Bad;` - this namespace is nested inside it, so the directive is
// redundant. InspectCode catches that and Roslyn does not, which is the whole
// reason the harness runs both engines rather than treating them as
// interchangeable.

// FIXED: the boundary is pinned, so mutating >= to > now fails a test.
public class DiscountTests
{
    [Fact]
    public void Apply_WellAboveThreshold_Discounts()
    {
        Assert.Equal(180m, Discount.Apply(200m));
    }

    [Fact]
    public void Apply_ExactlyAtThreshold_Discounts()
    {
        // The assertion that kills the >= -> > mutant.
        Assert.Equal(90m, Discount.Apply(100m));
    }

    [Fact]
    public void Apply_JustBelowThreshold_DoesNotDiscount()
    {
        Assert.Equal(99.99m, Discount.Apply(99.99m));
    }
}
'@

Write-Output 'Fixture rewritten to its clean form. Every gate should now exit 0.'
