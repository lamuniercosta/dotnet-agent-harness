# The code-review gate contract travels with the skill

`/code-review` was advisory by construction: the pipeline rule filed it under
non-gated supporting skills, `/refactor` told callers to mention it rather than
execute it, and its own file ended at a report addressed to a human who had
been told the skill was optional. The pipeline rewrite (DEV-182) made stage 9
gated in `agent-pipeline.mdc` and DEV-179 added `/remediate` as the consumer,
but none of that authority reached the skill itself — and the skill is invoked
outside pipeline order by two of its own callers: `/remediate` re-invokes it on
fix diffs, and `/ship-review` fans it out against the rebase delta. A gate
that lives only in the pipeline rule is advisory again exactly where its
findings get consumed.

## Decision

The gate contract lives in `skills/code-review/SKILL.md`, as the minimum three
additions. Everything already in the file stays byte-identical — the axes, the
severity scale, the blast-radius rule, the evidence threshold, step 7
verification, and the sub-agent dispatch table — because this change alters
the skill's authority and its sink, not a single judgment it makes.

1. **Step 0 resolves the three loop terms.** Closing bar, frozen scope, and
   round cap are read from the active feature's `brief.md`, with
   `/ship-review`'s resolution path and fail-closed rule. An unresolvable
   feature or term stops the review before it starts: **Could not run**, the
   missing context named, verdict **NEEDS FIXES**.
2. **Step 1 accepts `Explicit diff range: <fixed-point>...HEAD`.** When the
   caller supplies that single-line invocation-prompt field, the review covers
   only that three-dot range. `<fixed-point>` is the left side and is Step 3a's
   `fixed_point`; the right side is always `HEAD`. Callers that pin a concrete
   head make the workspace HEAD equal that pin, then pass
   `<fixed-point>...HEAD`. Malformed, unresolved, empty, or head-mismatched
   ranges fail closed before fan-out: **Could not run** with the failed range
   check, verdict **NEEDS FIXES**. `/remediate` passes
   `Explicit diff range: ROUND_BASE...HEAD` on later rounds, `/ship-review`
   `Explicit diff range: <stage-9-cleared-commit>...HEAD` for a non-empty
   rebase delta, and `/pr-review` `Explicit diff range: baseSha...HEAD` on a
   workspace at `headSha`. The pre-pass artifact is evidence, not a substitute
   for the field, and no artifact-path input replaces it.
3. **Step 8 sorts and hands off.** Verified findings above the closing bar go
   to `/remediate`; below-bar or out-of-scope findings become follow-ups,
   never silently relabelled, with source and severity retained either way.
   The stage clears only when no finding above the closing bar remains.

The round cap is read with the other terms but enforced by `/remediate`, which
owns the loop; the skill sorts against the bar and the frozen scope only. The
two step-8 sinks are unchanged, and what counts as a finding is unchanged.

## Rejected alternatives

**State the gate only in `agent-pipeline.mdc`.** The skill's own callers
invoke it outside pipeline order; a pipeline-only rule re-opens the advisory
gap on the fix-diff and rebase-delta paths, where findings actually change
code.

**Hand findings to `/remediate` through the DEV-177 JSON artifact.** That
artifact serves the foreign-PR path only, and the ticket freezes the sinks.
`/remediate` consumes findings plus a pinned range; a second serialization is
scope creep against the frozen acceptance list.

**Renumber the process steps.** Byte-identity of the protected sections is an
acceptance criterion. Inserting a step 0 and appending to steps 1 and 8 keeps
every protected section byte-identical and the diff pure additions.

**Assert the byte budget in the test suite.** The cost constraint is a
discipline for this change, not a permanent gate: DEV-122 will restructure
this skill for progressive disclosure, and a size assertion would fight that
work. The verifier measures and reports the number instead.

## Accepted cost

The largest skill in the tree (15,215 B) grows by up to ~1 KB against the
ticket's few-hundred-byte aspiration. Three fail-closed contract statements do
not compress much further without losing the greppable phrases the acceptance
checks and the install tests anchor to; the plan enforces a hard cap and a
cut order instead. An ad-hoc review with no resolvable feature or `brief.md`
now fails closed — the price of one contract everywhere, and the same price
`/ship-review` already charges.

## Consequences

Stage 9 has the same convergence discipline as stage 10: the loop terms
settled at stage 1 bind both review stages, `/remediate` receives a bounded,
self-shrinking input, and the loop terminates on the closing bar rather than
on review fatigue. `Test-InstallArtifacts.ps1` carries the contract assertions
so the adapted Codex copy cannot silently drop them.
