# Ship-review reuses code-review for the rebase delta

`/ship-review` runs after stage 9 `/code-review` has already cleared the task
branch and after stage 10 rebases that branch onto the latest default branch.
At that point its correctness lane should not repeat a full three-axis review
of the whole task diff. The only new correctness risk introduced between the
cleared tree and the pre-PR tree is the rebase delta.

## Decision

`/ship-review` keeps its full blocking `/verify` run and its security and
coverage lanes. When the rebase delta from the commit stage 9 cleared to the
rebased head is non-empty, the correctness lane invokes `/code-review` with
`Explicit ship-review rebase-delta range: <stage-9-cleared>..HEAD` — a
discriminated two-dot range that is ship-review-only. When the rebase delta is empty, ship-review records
a named correctness confirmation and does not invoke `/code-review`, so the
lane still appears in the three-lane readiness report without hitting
`/code-review`'s empty-diff fail-closed.

The rebase delta is the patch-id-filtered difference between the old and new
feature series, not a plain three-dot merge-base diff or a naive two-dot tree
diff. `old_base = git merge-base <stage-9-cleared> HEAD`, `new_base = git merge-base HEAD origin/main` (or `git merge-base --fork-point HEAD`). The old series `old_base..stage-9-cleared` and the new series `new_base..HEAD` are compared by patch-id / `git range-diff`: a new commit whose patch-id already exists in the old series is already-cleared feature work and is excluded, and commits that are ancestors of `new_base` (upstream churn) are not in the new series and are excluded. Empty-delta detection and the non-empty review use the same filtered comparison, and the artifact's diff evidence, filtered commit list, `fixed_point`, and `diff_range` are synchronized to that same scope.

The stage-9-cleared commit is an in-session fixed point. The skill documents
that callers must identify it from the current review session and must not
write a receipt or other state outside the working tree to recover it later.

The two-dot form is accepted only on the discriminated `Explicit ship-review rebase-delta range:` field. Ordinary scoped reviews (stage 9 and later fix rounds `ROUND_BASE...HEAD`, and `/pr-review` `baseSha...HEAD`) continue to use `Explicit diff range: <fixed-point>...HEAD` with three-dot merge-base semantics and still reject two-dot ranges, so a dropped-dot typo still fails closed with **Could not run** / **NEEDS FIXES**.

## Rejected alternatives

**Keep dispatching a bare `code-reviewer` agent.** That duplicates the old
`/code-review` shape with one sentence of instructions and loses the gate
contract added to the full skill: explicit ranges, fail-closed loop terms, and
bar/scope sorting.

**Run `/code-review` against the full task diff again.** Stage 9 already did
that before the rebase. Repeating it at ship time spends review budget on code
that has already cleared and hides the smaller question introduced by rebase:
whether upstream changes altered the already-reviewed result.

**Persist the fixed point in a receipt file.** The pipeline already has the
commit in session when stage 9 clears. Writing cross-run state creates a new
artifact contract for a single handoff value and expands the change beyond the
skill and rule wording this task needs.

**Use a plain three-dot `...HEAD` or naive two-dot `..HEAD` from `<stage-9-cleared>` to `HEAD` as the rebase delta.** Three-dot expands to already-cleared feature work when the stage-9-cleared commit is not an ancestor of the rebased HEAD (DEV-209). Naive two-dot compares the old feature tree directly to the rebased tree and pulls in unrelated upstream churn. Both violate the invariant that only the new correctness risk introduced by rebase is reviewed. The accepted patch-id-filtered / range-diff delta excludes both.

## Accepted cost

`/ship-review` now depends on the caller preserving the stage-9-cleared commit
through the stage 10 handoff. If that fixed point is missing or ambiguous, the
skill fails closed before fan-out with **Could not run** and **NEEDS FIXES**.
That is stricter than re-running an unscoped reviewer, but it preserves the
pipeline's evidence chain. The discriminated two-dot transport adds one more
explicit range shape for `/code-review` to validate, but it is isolated to the
ship-review handoff and does not weaken the three-dot contract for other callers.

## Consequences

Stage 10 remains rebase, `/ship-review`, then PR creation. The review is still
three lanes and still READY only when `/verify` passed, all required reviewers
ran, `Blocking` is empty, and no unresolved Critical or High finding remains.
Only the correctness lane's scope changes: a non-empty rebase delta becomes
a delegated `/code-review` invocation over the discriminated filtered delta; an empty delta is a
named confirmation and does not call `/code-review`. Security and Coverage consumers re-derive the same filtered semantics and verify `repository`, `head_sha`, `fixed_point`, and `diff_range` before trusting the ship-review artifact.
