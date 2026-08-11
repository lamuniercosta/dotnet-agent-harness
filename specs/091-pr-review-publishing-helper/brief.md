# Deterministic PR review publishing helper

Source: GitHub issue #91

## Problem

The harness has no packaged mechanism that can take an already-decided finding
list and publish it as one correctly located, retry-safe GitHub review. PR #86
mixed that mechanism with an unsettled review methodology. The publishing half
was hardened across nine rounds and should be salvaged without reviving the
methodology half.

## Shared understanding

- Publish mechanics only. `/code-review` and issue #90 own the decision about
  what constitutes a finding.
- Salvage the PowerShell helper, JSON schema, and self-test from `ad46328`; keep
  the single-file helper shape and remove `-WatchDecide`.
- The public surface has ten verbs: `-Resolve`, `-NewWorkspace`, `-Validate`,
  `-Fingerprint`, `-Dedupe`, `-BuildPayload`, `-Preflight`, `-Post`,
  `-MarkdownFallback`, and `-Ledger`.
- Parse paginated REST output page by page. Treat partial GraphQL data with
  top-level errors as incomplete coverage.
- Pin one base/head pair and re-read both at close. Abort if either moved.
- Identify a run by repository, PR number, head SHA, and run id. Reconcile a
  missing receipt through a marker embedded in the published body.
- Derive fingerprints inside the helper. Keep an exact identity and a
  location-independent identity that survives unrelated line movement.
- Build the diff map from the SHA-addressed compare result. At the 300-file cap,
  use the paginated PR-file fallback only after every entry is proven against
  the pinned head tree; otherwise report incomplete coverage.
- Treat the predictable workspace as an attack surface: owner-only from
  creation, owned by the current user, and never a symlink or reparse point.
- Treat every PR and repository surface as untrusted data. The helper may start
  only `gh` and must not interpret repository instructions as commands.
- Serialize concurrent posts for one run across reconcile, submit, and receipt
  write. Sequential retries must never duplicate a review.

## Scope

Add the canonical skill, helper, schema, acceptance self-test, cross-platform CI
matrix, ADR, domain vocabulary, changelog entry, release version updates, and
the canonical-skill install count.

Watch mode, try-fix probes, a multi-pass convergence protocol, deep-review
policy, route-map advertising, README workflow documentation, adapter
cross-references, script splitting, and a pinned-identity type are out of scope.

## Acceptance checks

1. Resolve by PR number, URL, or current branch for fork and same-repository PRs.
2. Preserve multi-page results and map files at and beyond the 300-file cap with
   pinned-tree proof for the fallback.
3. Preserve partial GraphQL data while reporting top-level errors as incomplete.
4. Abort publication when the pinned head or base moves.
5. Validate single-line, left/right, and multi-line comments; demote unmappable
   locations to the summary.
6. Match exact and location-independent dedupe identities while ignoring
   caller-supplied current-finding fingerprints.
7. Recover a missing receipt after a successful post and serialize concurrent
   posts for one run.
8. Enforce owner-only workspace creation and refuse foreign owners, symlinks,
   and reparse points on both supported platforms.
9. Run the helper self-test on both Windows and Linux in `lint-harness.yml`.

The acceptance list is closed for this issue. Additional coverage becomes a
follow-up rather than expanding this implementation.
