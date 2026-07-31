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
