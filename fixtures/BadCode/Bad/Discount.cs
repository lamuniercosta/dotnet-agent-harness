namespace Bad;

// VIOLATION: mutation gate.
// Apply is covered by a test, but no test pins the >= boundary, so Stryker's
// mutation of >= to > SURVIVES. Line coverage looks fine; the behaviour at the
// threshold is unasserted. This is the difference the mutation gate exists to
// expose.
public static class Discount
{
    public const decimal Threshold = 100m;

    public static decimal Apply(decimal total) =>
        total >= Threshold ? total * 0.9m : total;
}
