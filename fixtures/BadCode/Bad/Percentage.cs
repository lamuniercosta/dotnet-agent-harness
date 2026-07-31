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
