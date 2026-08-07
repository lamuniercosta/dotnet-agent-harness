---
name: verify
description: >
  Run a multi-phase verification pipeline for .NET projects — build, analyzers,
  complexity, inspections, tests, property tests, security, format, mutation, and
  diff review — reporting PASS/WARN/FAIL per phase and short-circuiting on
  critical failures.
  Use when: "verify", "check everything", "is this ready", "pre-PR check",
  "run all checks", "quality gate", or after completing a feature or refactor.
---

# Verify — Verification Pipeline

Adapted from [codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit) (MIT). The upstream Roslyn MCP phases are replaced with standard `dotnet` tooling plus this harness's gate scripts, so the skill has **no MCP dependency and no third-party service**.

## What it is

A sequential pipeline that answers one question: **"Is this code ready for review?"** Each phase reports PASS/WARN/FAIL. Critical failures (build, tests) short-circuit — later phases are meaningless on broken code.

This is the ad-hoc runner. It wraps the same scripts the gated pipeline uses, so readiness can be checked at any time without running the full `/refactor` → `/architect` sequence. It **complements** the gates; it does not replace them. "It looks fine" is not a result — a table of statuses is.

| Phase | Tool | Critical |
|---|---|---|
| 1. Build | `dotnet build` | Yes |
| 2. Analyzers | `./scripts/run-roslyn-analyzers.ps1` | Yes |
| 3. Complexity | `./scripts/run-cyclomatic-complexity.ps1` | Yes |
| 4. InspectCode | `./scripts/run-jetbrains-inspectcode.ps1` | Yes |
| 5. Tests | `dotnet test` | Yes |
| 6. Property tests | `./scripts/run-property-tests.ps1` | FAIL on counterexample |
| 7. Security | `./scripts/run-vulnerable-packages.ps1` + secret/injection review | FAIL on any vulnerable package |
| 8. Format | `dotnet format --verify-no-changes` | No |
| 9. Mutation | `dotnet stryker` (scoped: `--mutate "**/File.cs"`) | FAIL below threshold |
| 10. Diff review | `git diff` analysis | No |

Phases 2–4 are the **static-analysis gates**. They are not interchangeable — each catches a different class of problem, and `dotnet build` alone surfaces none of them reliably.

- **Roslyn analyzers** — CA/IDE/VSTHRD diagnostics at warning+ (CA1502 excluded; it belongs to phase 3). Catches `async void`, sync-over-async, missing `CancellationToken`, and the `BannedSymbols.txt` entries (`DateTime.Now` → `TimeProvider`).
- **Cyclomatic complexity** — CA1502 only, threshold from `harness.yml`. Separated because it is the one gate whose threshold tightens between stages.
- **InspectCode** — ReSharper/Rider inspections, a *different engine* from Roslyn. Close to a superset of phase 2 (ReSharper honours `.editorconfig` and re-reports CA/IDE rules), and it is the only engine here that reports duplication. Phase 2 still earns its place on speed: roughly 40s against several minutes.

These three — and only these three — share the `-BaseRef`/`-Files`/`-All` scope arguments: no args analyses changed `.cs` files vs the repo's default branch plus untracked; `-Files "a.cs","b.cs"` for an explicit set; `-All` for the whole solution. Phases 6, 7 and the gherkin-mutation gate scope differently (`-Project`/`-Category`, `-Severity`/`-IncludeTransitive`, `-Project`/`-SpecsPath`) and reject `-All` outright: PowerShell fails the parameter binding and the script exits 1 having scanned nothing. Treat that exit 1 as a bad invocation to fix, never as a failed gate.

Exit 0 = pass, 1 = fail, 2 = SKIPPED (verified nothing — never report it as a pass).

**A gate that is not wired refuses to run.** If the analyzer it depends on is not actually enabled, it exits 1 with remediation rather than reporting a pass it did not earn. Install the wiring with `./install.ps1 <repo>`. These scripts require PowerShell 7 (`pwsh`).

## Scope

Full pipeline before a PR. Scope down otherwise:

| Scenario | Phases | Complexity threshold |
|---|---|---|
| **After creating/editing any `.cs` file** | 2, 3, 4 | 15 |
| Before marking a task complete | 2, 3, 4, 5 | 15 |
| Pre-PR / feature complete | All 10 | 15 |
| **Refactor gate** | 2, 3, 4, 5, 6 | **6** (`-Threshold 6`) |
| Bug fix | 1, 2, 3, 5 (add a regression test first) | 15 |
| Dependency update | 1, 5, 7 | — |
| Config/test-only | 1, 5 | — |
| Formatting only | 8 | — |

The implementation bar is `gates.complexity.implement` (default **15**). The refactor gate is deliberately stricter at `gates.complexity.refactor` (default **6**) — run it after implementation is working, before any architecture pass:

```powershell
./scripts/run-cyclomatic-complexity.ps1 -Threshold 6
./scripts/run-roslyn-analyzers.ps1
./scripts/run-jetbrains-inspectcode.ps1
./scripts/run-property-tests.ps1
dotnet test
```

Fix complexity failures by extracting private helpers, early returns, and guard clauses — **not** by suppressing. `#pragma warning disable CA1502` is acceptable only for generated or genuinely unavoidable code, with a written justification. When an InspectCode finding is intentional (a fixed telemetry span name in a test, say), use a targeted ReSharper suppression comment rather than ignoring it.

Mutation (phase 9) is minutes-expensive — run pre-PR or when tests changed. InspectCode (phase 4) is a whole-solution pass taking tens of seconds; worth it per-task, not per-keystroke. Integration tests use Testcontainers; Docker must be running.

## How

```powershell
dotnet build --no-restore --verbosity quiet             # Phase 1
./scripts/run-roslyn-analyzers.ps1                      # Phase 2
./scripts/run-cyclomatic-complexity.ps1                 # Phase 3  (-Threshold 6 at the refactor gate)
./scripts/run-jetbrains-inspectcode.ps1                 # Phase 4
dotnet test --no-build --verbosity quiet                # Phase 5
./scripts/run-property-tests.ps1                        # Phase 6
./scripts/run-vulnerable-packages.ps1                   # Phase 7
dotnet format --verify-no-changes --verbosity quiet     # Phase 8
dotnet stryker                                          # Phase 9 (pre-PR)
```

When output would otherwise flood the conversation, use the named
**`gate-runner`** profile if the host loads it; otherwise give its bounded brief
to a general subagent. If neither is available, run inline and still summarize
each failure as `file:line` plus a one-line cause rather than returning raw output.

If `scripts/` is absent, the repo has not had the gates installed — run `./install.ps1 <repo>` from this harness. Do **not** silently fall back to plain `dotnet build` and call phases 2–4 passed; report them as SKIPPED with that remediation, since a skipped gate and a passed gate are not the same result.

Phase 7 also reviews changed files for hardcoded secrets/connection strings, raw SQL without parameterization, missing authorization, and permissive CORS. Phase 10 reviews `git diff` for stray `bin/`/`obj/`/secrets, debug leftovers (`Console.WriteLine`, `#if DEBUG`), unresolved TODO/HACK/FIXME, and scope mismatch.

### Fix-and-retry loop
1. **Identify** the failing phase and error.
2. **Fix** minimally.
3. **Re-run** from Phase 1 if code changed, else from the failed phase.
4. **Repeat** until all pass or an issue needs user input.

## Final summary

```
## Verification Results
| Phase | Result | Details |
|-------|--------|---------|
| 1. Build          | PASS | 0 errors, 0 warnings |
| 2. Analyzers      | PASS | 0 CA/IDE diagnostics |
| 3. Complexity     | PASS | max 11 (threshold 15) |
| 4. InspectCode    | PASS | 0 WARNING+ inspections |
| 5. Tests          | PASS | 47 passed |
| 6. Property tests | PASS | 12 properties, 0 counterexamples |
| 7. Security       | PASS | no vulnerable packages |
| 8. Format         | PASS | clean |
| 9. Mutation       | SKIP | run pre-PR |
| 10. Diff          | WARN | 1 TODO marker |

Verdict: READY FOR REVIEW (1 non-blocking warning)
```

Verdicts: **READY FOR REVIEW** (all PASS or only non-blocking WARN) or **NEEDS FIXES** (any FAIL, with remediation). For pre-PR runs, include the table in the PR description.

Report a gate that could not run as **SKIP** with the reason, never as PASS. A gate reporting PASS must have actually executed its analyzer.

## Related

- `/code-review` — multi-dimensional review once verification passes
- `/ship-review` — the pre-PR fan-out that runs after this
- `/diagnosing-bugs` — when a test phase goes red and the cause is unclear
