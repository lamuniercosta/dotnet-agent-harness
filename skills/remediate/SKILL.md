---
name: remediate
description: Drive already-accepted review findings to closure. Use when: remediate, close accepted findings, review-fix loop, stage 9 /remediate.
---

# Remediate

Input: the caller's **already-accepted** findings only. Do not classify, adjudicate, or decide the closing bar.

## 0. Resolve before any write

`FEATURE_DIR` from the active task context, else `.specify/scripts/powershell/check-prerequisites.ps1 -Json` (same as `/ship-review`). From `<FEATURE_DIR>/brief.md` resolve **closing bar**, **frozen scope**, and **round cap**. Cap comes from brief.md loop/closing guidance when present; default **two** only via `agent-pipeline` Loop Discipline. If any term is missing or ambiguous, stop and report exactly what is missing. No writes. Caller stage **NEEDS FIXES**.

## 1. Freeze as tasks

Append a remediation phase to `<FEATURE_DIR>/tasks.md` with frozen, countable `- [ ]` rows. Keep each finding's **source** and **severity** on the row or adjacent phase text (needed when deferring).

## 2. Each round

1. Pin an explicit pre-round baseline: `ROUND_BASE=$(git rev-parse HEAD)`. Later `/code-review` **must** get this fixed point / range.
2. Run `/implement` on this round's remediation rows with `REMEDIATION_ROUND=true` so `after_implement`'s `/refactor` receives it; **never call `/refactor` from this skill**.
3. Ignore `/refactor`'s `/architect` handoff. **Do not run `/architect` inside a round.**
4. The round fix diff is `git diff ROUND_BASE...HEAD` — every change since the pinned baseline, **including hooked `/refactor` output**. Do not review implement-only output.
5. Empty, unresolved, or unreviewable diff → fail closed. Never treat empty as clean. Stop; **NEEDS FIXES**.
6. Re-review with `/code-review` scoped to that pinned range only (not the whole change).
7. If accepted findings remain and the cap is not reached: append **only those** as the next remediation phase and repeat from step 1.
8. If clean: close the loop. If the cap is reached: **make no further fix commits**; report remaining findings with source and severity; leave caller stage **NEEDS FIXES**.

## 3. After loop or cap (once)

Run `/architect` **exactly once** against the accumulated remediation fixes. If the cap was reached with remaining findings, **NEEDS FIXES** wins even when `/architect` later reports clean/READY.

## Report

Rounds used; findings closed; findings deferred (source + severity); cap reached yes/no; final caller-stage disposition.
