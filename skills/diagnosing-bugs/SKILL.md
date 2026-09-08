---
name: diagnosing-bugs
description: Diagnosis loop for hard bugs and performance regressions in .NET codebases. Use when the user says "diagnose"/"debug this", or reports something broken/throwing/failing/slow.
---

# Diagnosing Bugs (.NET)

A discipline for hard bugs. Skip phases only when explicitly justified.

Assumes only .NET 8+, xUnit, and Docker. Concrete examples below name specific technologies (MongoDB, SQL Server, Redis, Hot Chocolate, gRPC) because a vague technique is useless — treat them as *instances of a pattern*, not as the stack. Read `harness.yml` and the repo's own `CLAUDE.md`/`AGENTS.md` for what is actually in use, and substitute the equivalent tool.

When exploring the codebase, read `CONTEXT.md` (if it exists) to get a clear mental model of the relevant modules, and check ADRs in the area you're touching.

## Phases

Phases are sequential. Load only the active phase. Do not read the next companion until the current phase's completion criterion is met.

| Phase | Completion criterion |
|-------|----------------------|
| 1. Build a feedback loop | Tight, red-capable, deterministic, fast, agent-runnable command already run at least once. No Phase 2 without it. |
| 2. Reproduce + minimise | User's failure mode reproduced and every remaining element is load-bearing. |
| 3. Hypothesise | 3–5 ranked falsifiable hypotheses shown to the user (proceed if AFK). |
| 4. Instrument | Each probe maps to a Phase 3 prediction; change one variable at a time. |
| 5. Fix + regression test | Regression test at a correct seam (or seam absence documented); Phase 1 loop re-run on the original scenario. |
| 6. Cleanup + post-mortem | Cleanup checklist complete; post-mortem question asked. |

Phase 1: Read ./phase-1-feedback-loop.md in this skill's directory

When Phase 1 is complete — Phase 2: Read ./phase-2-reproduce.md in this skill's directory

When Phase 2 is complete — Phase 3: Read ./phase-3-hypothesise.md in this skill's directory

When Phase 3 is complete — Phase 4: Read ./phase-4-instrument.md in this skill's directory

When Phase 4 is complete — Phase 5: Read ./phase-5-fix.md in this skill's directory

When Phase 5 is complete — Phase 6: Read ./phase-6-cleanup.md in this skill's directory
