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
`Explicit diff range: <stage-9-cleared-commit>...HEAD`. When the rebase delta is empty, ship-review records
a named correctness confirmation and does not invoke `/code-review`, so the
lane still appears in the three-lane readiness report without hitting
`/code-review`'s empty-diff fail-closed.

The stage-9-cleared commit is an in-session fixed point. The skill documents
that callers must identify it from the current review session and must not
write a receipt or other state outside the working tree to recover it later.

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

## Accepted cost

`/ship-review` now depends on the caller preserving the stage-9-cleared commit
through the stage 10 handoff. If that fixed point is missing or ambiguous, the
skill fails closed before fan-out with **Could not run** and **NEEDS FIXES**.
That is stricter than re-running an unscoped reviewer, but it preserves the
pipeline's evidence chain.

## Consequences

Stage 10 remains rebase, `/ship-review`, then PR creation. The review is still
three lanes and still READY only when `/verify` passed, all required reviewers
ran, `Blocking` is empty, and no unresolved Critical or High finding remains.
Only the correctness lane's scope changes: a non-empty rebase delta becomes
a delegated `/code-review` invocation over that range; an empty delta is a
named confirmation and does not call `/code-review`.
