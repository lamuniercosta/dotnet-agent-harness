using FsCheck;
using FsCheck.Xunit;
using Xunit;

namespace Bad.Tests;

// The property-test gate's fixture.
//
// In the BROKEN state Percentage.Clamp forgets its lower bound, so
// Clamp_AlwaysWithinBounds fails and run-property-tests.ps1 exits 1. In the
// FIXED state both properties hold and it exits 0.
//
// Note what this catches that the example-based tests below do not: every value
// a developer would think to try (0, 50, 100, 150) passes on the broken code.
// Only a negative exposes it, and nobody writes that example.
public class PercentageProperties
{
    // An explicit generator rather than Arb.From<decimal>().
    //
    // FsCheck's default decimal arbitrary did not produce negative values here,
    // so the property passed against the broken Clamp - a fixture that proves
    // nothing while looking like it works. Spelling out the range makes the
    // coverage visible and the failure deterministic.
    private static Arbitrary<decimal> AnyPercentageInput =>
        Arb.From(Gen.Choose(-500, 500).Select(i => i / 2m));

    [Property(MaxTest = 500)]
    [Trait("Category", "Property")]
    public Property Clamp_AlwaysWithinBounds()
    {
        return Prop.ForAll(AnyPercentageInput, value =>
        {
            var result = Percentage.Clamp(value);
            return result >= Percentage.Min && result <= Percentage.Max;
        });
    }

    [Property(MaxTest = 500)]
    [Trait("Category", "Property")]
    public Property Clamp_IsIdempotent()
    {
        // Holds in both states. It is here so a FAIL points at the specific
        // broken invariant rather than at the property suite being broken.
        return Prop.ForAll(AnyPercentageInput, value =>
            Percentage.Clamp(Percentage.Clamp(value)) == Percentage.Clamp(value));
    }

    // Example-based tests, deliberately all passing on the broken code.
    [Theory]
    [InlineData(0)]
    [InlineData(50)]
    [InlineData(100)]
    [InlineData(150)]
    public void Clamp_ObviousExamples_AreInRange(decimal value)
    {
        var result = Percentage.Clamp(value);
        Assert.InRange(result, Percentage.Min, Percentage.Max);
    }
}
