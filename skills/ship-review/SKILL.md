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

Cursor and Claude Code can route the roles below to the named profiles in
`.claude/agents/`. Codex does not load those profiles; spawn general subagents
with the table's briefs instead. If the host exposes no subagent mechanism, run
the briefs inline and disclose that fallback. This gate depends on no external
review service.

## When
- After implementation + refactor are complete, before creating the PR
- When the user says "ship", "ready to PR", "final review"

## Steps

### 1. Verify first (blocking)
Run `/verify` (full pipeline). Use the named **`gate-runner`** profile when the
host loads it; otherwise give the same bounded gate-running brief to a general
subagent or run it inline. If any critical phase FAILs, stop and fix — do not
review broken code.

### 2. Parallel fan-out
Dispatch all three in a **single message** so they run concurrently — they are independent, and running them in sequence wastes the main context on intermediate output.

| Reviewer | Agent | Brief |
|---|---|---|
| Correctness & design | `code-reviewer` | Three-axis review of the diff — Risk, Standards, Spec |
| Security | `security-reviewer` | `run-vulnerable-packages.ps1`, plus review for secrets/connection strings, injection, missing authorization, permissive CORS, PII in logs or telemetry attributes |
| Coverage | `mutation-analyst` | Coverage gaps and Stryker survivors against the change set |

Each brief gets: the diff command, the commit list, and the `/verify` results table.

### 3. Consolidate
Merge into one report, de-duplicating where two reviewers found the same thing (keep the more specific statement, note both sources):

```markdown
## Ship Review — <branch>
Verify: READY / NEEDS FIXES
### Blocking
- [source] finding + file:line + fix
### Non-blocking
- [source] finding + file:line
### Coverage
- Gaps / mutation survivors → add tests
```

### 4. Route
- Blocking findings → fix, re-run from step 1.
- Coverage gaps and surviving mutants → add tests, re-run mutation. A survivor means the test is inadequate — fix the test, not the threshold.
- All clear → summarise for human gate 3, then suggest opening the PR.

## Rules
- Do not open or push a PR automatically.
- Do not skip `/verify`.
- Keep findings actionable: source, `file:line`, concrete fix.
- If a reviewer could not run, report it as **SKIP** with the reason — never fold a missing axis into a clean verdict.

## Related
- `/verify` — the blocking gate this runs first
- `/code-review` — the same three-axis review, standalone
- `/pipeline` — where this sits in the stage order (gate 3)
