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
