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

A consolidated readiness review to run **before opening a PR** (stage 10, after rebase). Human gate 3 is merge at stage 12; this stage does not replace it.

Claude Code, Cursor, and Codex can route the roles below to their generated named
profiles. If the host exposes no subagent mechanism, run the briefs inline and
disclose that fallback. This gate depends on no external review service.

## When
- After `/code-review` is clean and the branch has been rebased, before creating the PR
- When the user says "ship", "ready to PR", "final review"

Read `.cursor/rules/github-workflow.mdc` (branch, commit, rebase, PR conventions)
and `.cursor/rules/readme-maintenance.mdc` (product README currency) — these are
the skill-load path for both rules at stage 10.

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
Identify the **stage-9-cleared commit** from the current review session — the
commit stage 9 `/code-review` cleared before the rebase. That fixed point is
in-session only: do not write a receipt or other state outside the working tree
to recover it. If the commit is missing or ambiguous, fail closed before
fan-out: report **Could not run** with the reason and verdict **NEEDS FIXES**.

First determine whether the rebase delta is empty — the diff from that
stage-9-cleared commit to the rebased head. If empty, record a named
correctness **confirmation** in the consolidated report and **do not invoke**
`/code-review`. That confirmation still counts as the lane having run: do not
skip the lane and do not treat emptiness as a missing reviewer. If non-empty,
invoke `/code-review` with that **explicit diff range**.

When that nested `/code-review` returns `declined: true` with a non-null
`decline_reason` and `findings: []`, or reports **out of scope for this skill**,
the correctness lane is **out of scope**, not a clean pass. Record it as
out-of-scope in the consolidated report. That is distinct from an empty rebase
delta's named confirmation, and it is not a missing reviewer — the lane ran.
Do not fold a declined nested review into a silently clean correctness result. This nested correctness-lane behavior follows ADR 0022 (docs/adr/0022-harness-targets-csharp-only.md): a declined no-C# /code-review is out of scope, not a clean correctness pass.

Before dispatching, write a pre-pass scratch artifact for Security and Coverage.

**Header** — the artifact starts with a Markdown header block containing these fields:

| Field | Source | Purpose |
|---|---|---|
| `repository` | Absolute path to the repo root | Prevents cross-repo collision |
| `branch` | Current branch name | Context for the reader |
| `head_sha` | Full 40-char `git rev-parse HEAD` | Freshness — must match consumer's HEAD |
| `fixed_point` | The stage-9-cleared commit | Prevents wrong-base stale reads |
| `diff_range` | The rebase-delta three-dot range | Explicit scope binding |
| `written_at` | UTC ISO-8601 timestamp | Audit trail; not used for verification |

A Security or Coverage consumer verifies `repository`, `head_sha`, `fixed_point`, and `diff_range` against its own environment before trusting the file. If the file is missing, unreadable, or any of those fields mismatch — or the lane cannot verify (no shell, wrong cwd) — it **fails closed**. No fallback to inline relay. `written_at` is not used for verification. `branch` is context for the reader.

**Body**: the diff command, the commit list, the rebase-delta summary, and the `/verify` results table. When the rebase delta is empty, the body also carries the named correctness confirmation.

**Allowed roots**: `<temp>/pr-review` and `<temp>/scratch` only. Both use the platform temporary directory, not a relative path. Working-tree roots are forbidden — no gitignore fallback. The path carries a repo-unique segment (for example a hash of the repo root's absolute path) **and this skill's own segment**, e.g. `<temp>/pr-review/<repo-hash>/ship-review/pre-pass-<full-40-char-sha>.md` (same shape under `<temp>/scratch/`), so two repos sharing a temp directory cannot collide and the nested `/code-review` pre-pass of the same repo can never write the same file. Filename: `pre-pass-<full-40-char-sha>.md`. Short SHAs are forbidden.

**Safe write**: if the target path is a symlink or reparse point, abort. Write to a temp file and rename onto the final path; never write the final path directly. If the target already exists with a different `fixed_point` or `head_sha`, abort rather than overwrite. On any abort: stop, report **Could not run** with the missing context, verdict **NEEDS FIXES**.

**Write-time freshness**: immediately before writing, re-resolve `git rev-parse HEAD`. If it differs from the HEAD captured when the rebase delta and `/verify` evidence were computed, abort (fail closed): stop, report **Could not run** with the missing context, verdict **NEEDS FIXES**.

**Read-only during fan-out**: `code-reviewer` and `security-reviewer` have no dedicated Edit or Write tools; Bash is available but not a sanctioned write path. Integrity during fan-out relies on that profile constraint, not filesystem permissions.

The ship-review artifact is **not** an input to nested `/code-review`. If
non-empty, `/code-review` receives the **explicit diff range** and computes its
own pre-pass (Steps 1–3a) over that range, writing an independent artifact
under its own `code-review/` subdirectory (not the `ship-review/` path). If empty,
`/code-review` is not invoked; Security and Coverage still consume the
ship-review artifact.

Dispatch security, coverage, and (when the rebase delta is non-empty) `/code-review` in a **single message** so they run concurrently — they are independent, and running them in sequence wastes the main context on intermediate output. On an empty rebase delta, record the correctness confirmation in that same turn rather than invoking `/code-review` or omitting the lane.

| Reviewer | Agent | Brief |
|---|---|---|
| Correctness & design | `/code-review` | First determine whether the rebase delta is empty. If empty: named confirmation, do not invoke `/code-review`, not a skipped lane. If non-empty: explicit diff range from stage-9-cleared commit to rebased head. If nested `/code-review` declines (no `.cs`): report the lane as **out of scope for this skill**, not a clean pass. |
| Security | `security-reviewer` | `run-vulnerable-packages.ps1`, plus review for secrets/connection strings, injection, missing authorization, permissive CORS, PII in logs or telemetry attributes |
| Coverage | `mutation-analyst` | Coverage gaps and Stryker survivors against the change set |

Security and coverage each get the path to the ship-review pre-pass artifact.
Each lane reads that file as its first action and verifies `repository`,
`head_sha`, `fixed_point`, and `diff_range` against its own environment. If the
file is missing, unreadable, or any of those fields mismatch — or the lane
cannot verify — it fails closed. Do not also relay the diff command, commit
list, or `/verify` table inline. Correctness gets the named confirmation when
the rebase delta is empty, or the explicit range when it is non-empty — never
the ship-review artifact path.

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
- READY requires `/verify` passed, all three reviewers ran, `Blocking` empty, and no unresolved Critical/High finding anywhere in the consolidated report, regardless of bucket. Missing loop terms or a missing reviewer remain **NEEDS FIXES**. A Critical or High finding deferred to `Follow-ups` does not cause another post-cap fix commit, but it still prevents READY and any PR suggestion. A declined / out-of-scope nested `/code-review` still counts as the correctness reviewer having run, but the report must name the lane as out of scope rather than clean.
- All clear (that readiness floor met) → summarise readiness and suggest opening the PR. Human gate 3 is merge at stage 12, after the PR exists.

## Rules
- Do not open or push a PR automatically.
- Do not skip `/verify`.
- Keep findings actionable: source, `file:line`, severity, concrete fix.
- If a reviewer could not run, report **Could not run** with the reason — never fold a missing axis into a clean verdict. Missing axes keep the verdict **NEEDS FIXES**.

## Related
- `/verify` — the blocking gate this runs first
- `/code-review` — the correctness lane over the rebase delta; also standalone at stage 9
- `/pipeline` — where this sits in the stage order (stage 10, after rebase and before the PR)
- `.cursor/rules/github-workflow.mdc` — branch, commit, rebase, and PR conventions
- `.cursor/rules/readme-maintenance.mdc` — product README currency before ship
