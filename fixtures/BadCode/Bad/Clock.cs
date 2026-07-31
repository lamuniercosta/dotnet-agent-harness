namespace Bad;

// VIOLATION: BannedSymbols.txt / RS0030 (configured as an ERROR).
// DateTime.Now is machine-local and makes every test that touches it
// non-deterministic. The fix is TimeProvider injection.
public static class Clock
{
    public static DateTime Stamp() => DateTime.Now;
}
