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

Exit 0 = pass, 1 = fail, 2 = SKIPPED or OPT-OUT (see classification in step 4).

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

Phases 2–3 run `dotnet build --no-incremental` internally — the flag forces
recompilation so analyzer diagnostics are emitted. Do not substitute a
standalone `dotnet build` for these phases; the gate scripts are the
authoritative invocation.

When output would otherwise flood the conversation, use the named
**`gate-runner`** profile if the host loads it; otherwise give its bounded brief
to a general subagent. If neither is available, run inline and still summarize
each failure as `file:line` plus a one-line cause rather than returning raw output.

If `scripts/` is absent, the repo has not had the gates installed — run `./install.ps1 <repo>` from this harness. Do **not** silently fall back to plain `dotnet build` and call phases 2–4 passed; report them as **Could not run** with that remediation. Reserve **Skipped** for a scope-empty exit 2; a configured opt-out (exit 2 whose output contains SKIPPED - disabled in harness.yml) is **Skip**, not **Skipped**.

Phase 7 also reviews changed files for hardcoded secrets/connection strings, raw SQL without parameterization, missing authorization, and permissive CORS. Phase 10 reviews `git diff` for stray `bin/`/`obj/`/secrets, debug leftovers (`Console.WriteLine`, `#if DEBUG`), unresolved TODO/HACK/FIXME, and scope mismatch.

### Fix-and-retry loop
**Do not edit `harness.yml` during a verify run to clear a gate result.** Disabling a gate mid-verify recasts a real finding as an opt-out, exactly the false-pass acceptance #2 exists to prevent. A gate configuration change is a project decision made before the run, not a fix applied during it. If the opt-out is genuinely warranted, document the reason, commit the `harness.yml` change as a separate commit, and start a fresh verify. The fresh verify's final summary must list all gates currently disabled in `harness.yml`, so the reviewer sees what is opted out and can trace each opt-out to a committed reason.

1. **Identify** the failing phase and its `file:line` errors.
2. **Fix** minimally.
3. **Re-run** from Phase 1 if code changed, else from the failed phase.
   Use the `gate-runner` profile or a subagent for each re-run — do not
   paste raw gate output into the conversation. Summarize each retry as
   one line: phase name, exit code, error count.
4. **Classify** every exit:
   - 0 = PASS
   - 1 = FAIL
   - 2 = check the gate's output:
     - If the output contains `SKIPPED - disabled in harness.yml` → **OPT-OUT** (non-blocking). Report as `SKIP` in the Result column. The project has deliberately turned this gate off; no retry. Match the full prefix, not just "disabled".
     - Otherwise → **SKIPPED** (blocking). The gate found nothing in scope to verify. Remediation below.
   Resolve a SKIPPED phase by its type:
   - Phases 2–4 (static-analysis gates): first check for OPT-OUT — if the gate output says `SKIPPED - disabled in harness.yml`, report as `SKIP` (non-blocking); no retry. Otherwise (scope-empty): re-run with `-All` to check the whole solution, or confirm no `.cs` files are in scope.
   - Phase 4 note: a disabled InspectCode means ReSharper inspections and duplication detection are off — note this alongside the `SKIP` verdict.
   - Phase 6 (property tests): add FsCheck properties or remove Skip attributes. If the project should opt out entirely, that is a `harness.yml` change subject to the mid-verify rule above — separate commit, fresh verify.
   - Phase 7 (vulnerable packages): verify `gates.vulnerablePackages.fail: true` is set and re-run. If the gate should remain disabled, that is a `harness.yml` opt-out subject to the mid-verify rule above.
   Do not offer `-All` to phases 6/7 — they reject it (exit 1, bad
   invocation per SKILL.md scope rules). A phase that could not run
   (missing scripts/tools) is **Could not run**, not SKIPPED or PASS.
5. **Repeat** until all phases pass or are deliberately opted out, or an
   issue needs user input. Best practice: cap fix-and-rerun attempts at
   3 per phase — if still failing, stop and report.

## Final summary

```
## Verification Results (all pass)
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
| 9. Mutation       | SKIP | not run pre-PR |
| 10. Diff          | WARN | 1 TODO marker |

Verdict: READY FOR REVIEW (1 non-blocking warning)

## Verification Results (needs fixes)
| Phase | Result | Details |
|-------|--------|---------|
| 1. Build          | PASS | 0 errors, 0 warnings |
| 2. Analyzers      | SKIPPED | no .cs files changed — re-run with -All |
| 3. Complexity     | PASS | max 8 (threshold 15) |
| 4. InspectCode    | Could not run | jb tool not in manifest |
| 5. Tests          | PASS | 23 passed |
| 6. Property tests | SKIPPED | no tests tagged — add or opt out |
| 7. Security       | PASS | no vulnerable packages |
| 8. Format         | PASS | clean |
| 9. Mutation       | SKIP | not run pre-PR |
| 10. Diff          | PASS | clean |

Verdict: NEEDS FIXES (2 SKIPPED, 1 Could not run — remediation above)
```

Verdicts: **READY FOR REVIEW** (all PASS, deliberate SKIP, or non-blocking
WARN) or **NEEDS FIXES** (any FAIL, SKIPPED, or Could not run — with
remediation for each).

**OPT-OUT** (`SKIP` in the Result column) does not block the verdict — the project has deliberately disabled the gate in `harness.yml`. **SKIPPED** (exit 2, scope-empty — the gate found nothing in scope to verify) and **Could not run** (missing tool/script, exit 1) do block it. The visual distinction: `SKIP` vs `SKIPPED` vs `Could not run`.

For pre-PR runs, include the table in the PR description.

Report a gate that could not run as **Could not run** with the reason, never as **Pass**. A gate reporting **Pass** must have actually executed its analyzer.

## Related

- `/code-review` — multi-dimensional review once verification passes
- `/ship-review` — the pre-PR fan-out that runs after this
- `/diagnosing-bugs` — when a test phase goes red and the cause is unclear
