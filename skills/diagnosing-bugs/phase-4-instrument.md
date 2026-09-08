# Phase 4 — Instrument

Each probe must map to a specific prediction from Phase 3. **Change one variable at a time.**

Tool preference:

1. **Debugger / REPL inspection** if the env supports it. One breakpoint beats ten logs. Where no debugger is attachable, a throwaway xUnit fact that calls the suspect method and prints intermediate state is the next best thing.
2. **Targeted logs** at the boundaries that distinguish hypotheses — `ILogger` or `Console.WriteLine`, it doesn't matter, they're dying soon anyway.
3. Never "log everything and grep".

**Tag every debug log** with a unique prefix, e.g. `[DEBUG-a4f2]`. Cleanup at the end becomes a single grep. Untagged logs survive; tagged logs die.

**Perf branch.** For performance regressions, logs are usually wrong. Instead: establish a baseline measurement first — `BenchmarkDotNet` for method-level, `dotnet-counters monitor` for GC/threadpool/allocation symptoms, `dotnet-trace` for CPU sampling, MongoDB `.Explain()` / `$indexStats` for query plans, SQL Server actual execution plans for SQL paths, Hot Chocolate's `IExecutionDiagnosticEvents` or Apollo-style tracing for resolver timing. Then bisect. Measure first, fix second. The classic .NET culprits: N+1 resolver fan-out without a DataLoader, missing MongoDB index (COLLSCAN in the explain output), sync-over-async (`.Result`/`.Wait()`) starving the threadpool, and LOH allocations from large payloads.
