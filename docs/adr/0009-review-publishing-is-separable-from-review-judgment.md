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

## Known gap

On Windows the workspace is created and then tightened, not created tight. The
POSIX path applies 0700 as part of the directory create — `Directory.CreateDirectory`
with a mode — so no other user ever holds a handle to a permissive version of it.
Windows has no mode-carrying create: `New-PrivateDirectory` calls `New-Item` and
the owner-only DACL is applied immediately afterwards by `Set-PrivateDirectoryMode`.
Between those two calls the new directory carries whatever ACL it inherits from its
parent. On a host where TEMP is redirected to a shared, world-inheritable location,
another local user could open a handle in that window and keep it across the
tightening.

The exposure is bounded. Every level of the predictable tree —
`pr-review/<owner>-<repo>`, `<pr>-<sha>`, and the per-run directories — is created
through the same path, so once a level has been locked down the ACL its children
inherit is already the restricted one, and `Assert-WindowsWorkspaceOwner` refuses
any directory this user does not own before the workspace is used. The residual
race is the first create under a freshly redirected, shared TEMP, before the
top-level `pr-review` directory has been tightened. Closing it needs a native
create-with-security-descriptor call (`CreateDirectoryW` with a
`SECURITY_ATTRIBUTES`), which is deferred rather than added here because it trades
the salvage's PowerShell-only footprint for P/Invoke. It is recorded so that a
future change makes that trade deliberately rather than discovering the gap again.

## Consequences

Review judgment can evolve without changing publication safety, and the helper
can publish findings from any workflow that satisfies the JSON contract. The
mechanical acceptance suite runs the real helper against a fake `gh` on Windows
and Linux. Future structural refactoring must preserve that suite and the ten-
verb contract.
