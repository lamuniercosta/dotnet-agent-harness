# Review publishing is separable from review judgment

The abandoned PR #86 combined two different problems: deciding which review
concerns are real and publishing the already-decided findings to GitHub. The
publishing helper converged under repeated review, while the methodology and
convergence protocol did not. Keeping them together would discard hardened
mechanism or ship unsettled judgment policy merely to preserve one feature
boundary.

## Decision

Package `pr-review` as a publication mechanism with ten verbs: resolve, create a
workspace, validate, fingerprint, deduplicate, build a payload, preflight, post,
render a Markdown fallback, and summarize a ledger. It accepts findings from a
separate review workflow and publishes one GitHub `COMMENT` review. It never
discovers findings or decides their validity, severity, category, or evidence.

Publication is bound to one pinned base/head pair. Both SHAs are re-read at the
close of the operation, and movement aborts the run. A run is identified by the
repository, PR number, head SHA, and run id; a head SHA alone is not identity.
The review body carries a run marker and the workspace carries a receipt so a
sequential retry can reconcile a post that reached GitHub before local receipt
persistence. One lock covers reconcile through receipt write for concurrent
posts of the same run.

The helper uses `gh` as its only external process. PR data and repository
content are untrusted input, including diff text, bodies, suggestion fences,
textconv configuration, and repository instruction files. Workspaces live
outside the checkout and must be owner-only, owned by the current user, and free
of symlinks or reparse points before use.

## Rejected alternatives

**Keep the convergence protocol in the skill.** That was the part of #86 that
did not converge. It also makes publication depend on one review methodology,
despite publication needing none of its axes, severity policy, or stopping rule.

**Rewrite the helper while extracting it.** Nine review rounds found failures in
pagination, mutable diff identity, partial GraphQL responses, retry recovery,
dedupe, and workspace trust. A rewrite would reopen those defects without
changing the mechanism's contract.

**Add a connector fallback.** A second publication path would need to duplicate
the pinned-pair, reconciliation, locking, location, and receipt guarantees. A
partial fallback would be observably less safe while presenting the same skill
surface.

**Split the script or introduce a pinned-identity type now.** Those are useful
structural changes but are separable from behavior. They remain deferred to
issue #89 so this salvage can be reviewed against unchanged mechanics.

## Accepted cost

The salvaged script remains large and PowerShell-specific. Its size is accepted
because this change preserves hardened behavior rather than redesigning it.
Consumers also need PowerShell 7 and an authenticated `gh` for online verbs.

The publisher is intentionally incomplete on its own: another workflow must
produce findings first. Issue #90 owns that review judgment. Watch mode,
try-fix probes, multi-pass convergence, and deep-review policy are absent rather
than implied.

## Consequences

Review judgment can evolve without changing publication safety, and the helper
can publish findings from any workflow that satisfies the JSON contract. The
mechanical acceptance suite runs the real helper against a fake `gh` on Windows
and Linux. Future structural refactoring must preserve that suite and the ten-
verb contract.
