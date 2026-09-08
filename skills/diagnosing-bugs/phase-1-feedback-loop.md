# Phase 1 — Build a feedback loop

**This is the skill.** Everything else is mechanical. If you have a **tight** pass/fail signal for the bug — one that goes red on _this_ bug — you will find the cause; bisection, hypothesis-testing, and instrumentation all just consume it. If you don't have one, no amount of staring at code will save you.

Spend disproportionate effort here. **Be aggressive. Be creative. Refuse to give up.**

### Ways to construct one — try them in roughly this order

1. **Failing xUnit test** at whatever seam reaches the bug — unit, integration, or end-to-end. Run it narrowly and fast:
   ```bash
   dotnet test --filter "FullyQualifiedName~OrderCancellationTests" --nologo -v q
   ```
   For integration seams, prefer `WebApplicationFactory<Program>` so the whole ASP.NET pipeline (middleware, DI, Hot Chocolate) is in the loop without a running server.
2. **Curl / HTTP script** against a running dev server. For Hot Chocolate, POST the exact failing operation:
   ```bash
   curl -s http://localhost:5000/graphql \
     -H 'Content-Type: application/json' \
     -d '{"query":"query { order(id: \"...\") { status } }"}' | jq -e '.errors == null'
   ```
   The `jq -e` exit code makes it pass/fail. For gRPC, use `grpcurl` with the same pattern.
3. **CLI invocation** with a fixture input, diffing stdout against a known-good snapshot (`dotnet run --project tools/Repro -- fixture.json | diff - expected.txt`).
4. **Replay a captured payload.** Save the real GraphQL request body, gRPC message, or queue message to disk; replay it through the code path in isolation — a throwaway xUnit fact that deserializes the file and calls the handler directly.
5. **Throwaway harness.** Spin up a minimal subset of the system with real infrastructure via **Testcontainers** (a container for whichever store the repo uses — Mongo, Postgres, SQL Server, Redis), mocked everything else, exercising the bug code path with a single method call. Data-shape bugs often only reproduce against the real engine: a mocked data-access interface will lie to you about serialisation, ID handling, and query translation. This is why the constitution forbids mocking the driver for query-translation behaviour.
6. **Property / fuzz loop.** If the bug is "sometimes wrong output", run 1000 random inputs (FsCheck, or a plain seeded `for` loop) and look for the failure mode.
7. **Bisection harness.** If the bug appeared between two known states:
   ```bash
   git bisect start HEAD <known-good-sha>
   git bisect run dotnet test --filter "FullyQualifiedName~TheReproTest" --nologo
   ```
8. **Differential loop.** Run the same input through old vs new version (or two configs, e.g. two `appsettings` variants) and diff outputs.
9. **HITL bash script.** Last resort. If a human must click, drive _them_ with `scripts/hitl-loop.template.sh` so the loop is still structured. Captured output feeds back to you.

Build the right feedback loop, and the bug is 90% fixed.

### Tighten the loop

Treat the loop as a product. Once you have _a_ loop, **tighten** it:

- **Faster.** Narrow the `--filter`, reuse a single Testcontainers instance via a collection fixture (`ICollectionFixture<MongoFixture>`), skip unrelated `Program.cs` init with a test-specific `WebApplicationFactory` override. `dotnet test` cold-start is the enemy — consider `dotnet watch test --filter ...` for sub-second re-runs.
- **Sharper.** Assert on the specific symptom (the exact error message, the wrong field value, the duplicate document), not "didn't throw".
- **More deterministic.** Pin time with `FakeTimeProvider` (`Microsoft.Extensions.TimeProvider.Testing`) — .NET 8's `TimeProvider` exists precisely so `DateTime.UtcNow` stops making tests flaky. Seed `Random`. Isolate the database per run (unique database name per test, dropped on dispose). Freeze network with mocked `HttpMessageHandler`.

A 30-second flaky loop is barely better than no loop; a 2-second deterministic one is tight — a debugging superpower.

### Non-deterministic bugs

The goal is not a clean repro but a **higher reproduction rate**. Loop the trigger 100×, parallelise (`Parallel.ForEachAsync` in a harness, or xUnit's default per-collection parallelism), add stress, narrow timing windows, inject delays around suspected races (`Task.Delay` at await points). Async races and MongoDB write-concern surprises are the usual .NET suspects. A 50%-flake bug is debuggable; 1% is not — keep raising the rate until it's debuggable.

### When you genuinely cannot build a loop

Stop and say so explicitly. List what you tried. Ask the user for: (a) access to whatever environment reproduces it, (b) a captured artifact (Seq/structured log export, a `dotnet-dump` or `dotnet-gcdump` capture, a HAR file, an APM trace with timestamps), or (c) permission to add temporary production instrumentation. Do **not** proceed to hypothesise without a loop.

### Completion criterion — a tight loop that goes red

Phase 1 is done when the loop is **tight** and **red-capable**: you can name **one command** — a test invocation, a script path, a curl — that you have **already run at least once** (paste the invocation and its output), and that is:

- [ ] **Red-capable** — it drives the actual bug code path and asserts the **user's exact symptom**, so it can go red on this bug and green once fixed. Not "runs without erroring" — it must be able to _catch this specific bug_.
- [ ] **Deterministic** — same verdict every run (flaky bugs: a pinned, high reproduction rate, per above).
- [ ] **Fast** — seconds, not minutes.
- [ ] **Agent-runnable** — you can run it unattended; a human in the loop only via `scripts/hitl-loop.template.sh`.

If you catch yourself reading code to build a theory before this command exists, **stop — jumping straight to a hypothesis is the exact failure this skill prevents.** No red-capable command, no Phase 2.
