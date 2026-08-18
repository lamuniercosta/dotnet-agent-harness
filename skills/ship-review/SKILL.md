---
name: ship-review
description: >
  Pre-PR review gate. Runs verification, then fans out a parallel review —
  code review, security review, and mutation/coverage analysis — and
  consolidates findings before opening a PR.
  Use when: "ship", "ready to PR", "final review", "ship review", "pre-PR review".
disable-model-invocation: true
---

# Ship Review (pre-PR gate)

Inspired by the [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) `/ship` fan-out (MIT), re-mapped to this harness's pipeline and its own agents.

A consolidated readiness review to run **before opening a PR**. It feeds human gate 3; it does not replace it.

Claude Code, Cursor, and Codex can route the roles below to their generated named
profiles. If the host exposes no subagent mechanism, run the briefs inline and
disclose that fallback. This gate depends on no external review service.

## When
- After implementation + refactor are complete, before creating the PR
- When the user says "ship", "ready to PR", "final review"

## Steps

Resolve the active `FEATURE_DIR` the same way as `/pipeline`: use the value
already established for the task, or run
`.specify/scripts/powershell/check-prerequisites.ps1 -Json` when possible. Read
`<FEATURE_DIR>/brief.md` for the three loop terms — **closing bar**, **frozen
scope**, and **round cap** — before `/verify` or fan-out. If the active feature or
any term cannot be resolved unambiguously, fail closed: stop before Step 1,
report **Could not run** with the missing context and verdict **NEEDS FIXES**.
Do not infer defaults, choose among multiple briefs, or suggest a PR.

### 1. Verify first (blocking)
Run `/verify` (full pipeline). Use the named **`gate-runner`** profile when the
host loads it; otherwise give the same bounded gate-running brief to a general
subagent or run it inline. If any critical phase FAILs, stop and fix on the same
shared round counter defined in Step 4 — do not fan out. Past the cap, make no
further fix commits; keep the verdict **NEEDS FIXES** and stop without fan-out.

### 2. Parallel fan-out
Dispatch all three in a **single message** so they run concurrently — they are independent, and running them in sequence wastes the main context on intermediate output.

| Reviewer | Agent | Brief |
|---|---|---|
| Correctness & design | `code-reviewer` | Three-axis review of the diff — Risk, Standards, Spec |
| Security | `security-reviewer` | `run-vulnerable-packages.ps1`, plus review for secrets/connection strings, injection, missing authorization, permissive CORS, PII in logs or telemetry attributes |
| Coverage | `mutation-analyst` | Coverage gaps and Stryker survivors against the change set |

Each brief gets: the diff command, the commit list, and the `/verify` results table.

### 3. Consolidate
Merge into one report, de-duplicating where two reviewers found the same thing (keep the more specific statement, note both sources).

Fix-commit routing is not readiness. Sort each finding against `brief.md`'s closing bar and frozen scope to decide whether it gets a fix commit in the current loop — the bar and scope come from `brief.md`, not the sub-agent's judgment. A finding that does not meet the closing bar, or falls outside the frozen scope, goes to `Follow-ups`; it is never silently relabelled `Non-blocking`. Keep the original source and severity.

```markdown
## Ship Review — <branch>
Verify: READY / NEEDS FIXES
### Blocking
- [source] finding + file:line + severity + fix
### Coverage
- Gaps / mutation survivors → add tests
### Follow-ups
- Below the bar, outside scope, or past the round cap: [source] finding + file:line + severity
```

### 4. Route
One round counter covers every fix-and-re-run route in this skill, including a
failed `/verify`, Blocking findings that re-run from step 1, and coverage gaps or
mutation survivors. Use the round cap recorded in `brief.md`; the
`agent-pipeline` rule's default is two, so the initial pass is round one and one
fix-and-re-run is round two. After the cap, unresolved review items move to
`Follow-ups` with source and severity retained; make no further fix commits.
- Blocking findings → fix, re-run from step 1, on that counter. After the cap they move to `Follow-ups`, not another fix commit.
- Coverage gaps and surviving mutants → add tests, re-run mutation, on that counter. After the cap they move to `Follow-ups` with source and severity retained. A survivor means the test is inadequate — fix the test, not the threshold.
- READY requires `/verify` passed, all three reviewers ran, `Blocking` empty, and no unresolved confirmed Critical/High finding anywhere in the consolidated report, regardless of bucket. Missing loop terms or a missing reviewer remain **NEEDS FIXES**. A confirmed Critical or High finding deferred to `Follow-ups` does not cause another post-cap fix commit, but it still prevents READY and any PR suggestion.
- All clear (that readiness floor met) → summarise for human gate 3, then suggest opening the PR.

## Rules
- Do not open or push a PR automatically.
- Do not skip `/verify`.
- Keep findings actionable: source, `file:line`, severity, concrete fix.
- If a reviewer could not run, report **Could not run** with the reason — never fold a missing axis into a clean verdict. Missing axes keep the verdict **NEEDS FIXES**.

## Related
- `/verify` — the blocking gate this runs first
- `/code-review` — the same three-axis review, standalone
- `/pipeline` — where this sits in the stage order (gate 3)
