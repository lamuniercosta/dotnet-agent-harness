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
