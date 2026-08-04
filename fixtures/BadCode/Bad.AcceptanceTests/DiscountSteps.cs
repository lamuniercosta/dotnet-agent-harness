using Reqnroll;
using Xunit;

namespace Bad.AcceptanceTests;

// Bindings for specs/discount.feature. Instance state is safe: Reqnroll creates
// a fresh binding instance per scenario, and it keeps CA1822 quiet without a
// suppression.
//
// The mutation gate replaces the first Then with a step that has no binding.
// These bindings genuinely assert, so the mutated scenario fails - the mutant
// is killed. Assert-Gates proves the other direction by swapping this file for
// a catch-all binding that matches everything and asserts nothing.
[Binding]
public sealed class DiscountSteps
{
    private decimal _charged;

    [Given("a shopping total of {float}")]
    public void GivenAShoppingTotalOf(double total)
    {
        _charged = (decimal)total;
    }

    [When("the discount is applied")]
    public void WhenTheDiscountIsApplied()
    {
        _charged = Discount.Apply(_charged);
    }

    [Then("the charged total should be {float}")]
    public void ThenTheChargedTotalShouldBe(double expected)
    {
        Assert.Equal((decimal)expected, _charged);
    }
}
