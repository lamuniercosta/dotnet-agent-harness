# Pre-pass artifact deduplicates review evidence

`/code-review` Steps 1–3 compute the diff command, commit list, blast-radius
table, Roslyn pre-pass, and tooling-gate results. Step 6 relays all of this
inline into every sub-agent prompt (Risk, Standards, Spec, and conditionally
Security) — up to four copies of the same evidence in the parent context.
`/ship-review` Step 2 does the same with the diff command, commit list, and
`/verify` results table across three lanes. Each relay duplicates a full copy
in the parent's context window, and the parent discards it immediately after
dispatching.

## Context

The duplicated payload is computed once and is identical for every axis. Fan-out
must stay intact: sub-agents remain isolated and each axis still receives the
same evidence it needs. The parent must stop carrying a full inline copy of that
evidence in every prompt. A scratch file consumed as input evidence must be
scoped, readable, and unable to become a source of stale or planted
conclusions.

ADRs 0018–0020 are claimed by in-flight branches: 0018 by DEV-121
(`0018-glob-and-skill-scoping-for-pipeline-rules.md`), 0019 and 0020 by
DEV-123. This decision is recorded as ADR 0021.

## Decision

Pre-pass evidence is written once to a scratch Markdown file. The parent
passes that file's path to each sub-agent. Sub-agents read the file themselves
instead of receiving the evidence inline. There is no fallback to inline
relay.

`/code-review` writes the artifact in a new Step 3a after Steps 1–3 and before
Step 4, then reports the absolute path for Step 6. `/ship-review` writes its
own artifact in Step 2 before dispatching Security and Coverage.

### Header, freshness, scope, and fail-closed rules

Every pre-pass artifact carries a Markdown header block. A consumer must
verify every field below before trusting the contents:

| Field | Source | Purpose |
|---|---|---|
| `repository` | Absolute path to the repo root | Prevents cross-repo collision |
| `branch` | Current branch name | Context for the reader |
| `head_sha` | Full 40-char `git rev-parse HEAD` | Freshness — must match consumer's HEAD |
| `fixed_point` | The left side of the accepted `Explicit diff range: <fixed-point>...HEAD` when present; otherwise the base ref or SHA from Step 1 | Prevents wrong-base stale reads |
| `diff_range` | The accepted explicit range when present; otherwise `<fixed-point>...HEAD` | Explicit scope binding |
| `written_at` | UTC ISO-8601 timestamp | Audit trail; not used for verification |

The consumer verifies `head_sha`, `fixed_point`, `diff_range`, and
`repository` against its own environment. If any mismatch or the file is
missing, the sub-agent **fails closed** — no fallback to inline relay, no
partial read. Inability to verify (no shell access, wrong cwd, file unreadable)
is also fail-closed.

The file body contains, in order:

1. **Diff command** — `git diff` of the accepted `diff_range` (explicit range when present; otherwise `git diff <fixed-point>...HEAD`)
2. **Commit list** — `git log <fixed-point>..HEAD --oneline` (`fixed_point` is the left side of the accepted range when present)
3. **Blast-radius table** — the scored table from Step 2 (code-review) or the
   rebase-delta summary (ship-review)
4. **Roslyn pre-pass results** — from Step 3, when available; section omitted
   when the Roslyn MCP tools are unavailable
5. **Tooling-gate status** — `dotnet format --verify-no-changes` and
   `dotnet build` pass/fail, with diagnostics on failure
6. **Severity scale** — the fixed scale from Step 8, so sub-agents can
   reference it without the parent relaying it inline

Items not in the artifact (relayed inline or absent by design):

- **Smell baseline** — fixed reference text; stays inline in the Standards
  sub-agent prompt (not computed evidence; no token savings from file
  delivery)
- **Standards-source list** — step 5 output; Standards sub-agent receives it
  inline alongside the smell baseline
- **Spec source** — step 4 output; Spec sub-agent receives the spec path
  inline

**Allowed roots**: `<temp>/pr-review` and `<temp>/scratch` only. Both use the
`<temp>/` prefix — the platform's temporary directory, not a relative path.

**Working-tree roots are forbidden.** The predictable filename
(`pre-pass-<sha>.md`) plus `.gitignore` lets a hostile branch plant a
freshness-passing artifact. Unlike the findings artifact, this one is consumed
as input evidence — a planted file silently corrupts the review. No gitignore
fallback.

**Repo-scoped path**: the path includes a repo-unique segment (e.g. a hash of
the repo root's absolute path) **and a skill-unique subdirectory** so two
repos sharing a user's temp directory never collide and `/code-review` and
`/ship-review` never write the same file. Under either allowed root the
shape is
`<temp>/pr-review/<repo-hash>/code-review/pre-pass-<full-40-char-sha>.md`
versus
`<temp>/pr-review/<repo-hash>/ship-review/pre-pass-<full-40-char-sha>.md`
(same skill segments under `<temp>/scratch/`). Shared allowed roots do not
make the two artifacts the same path.

**Filename**: `pre-pass-<full-40-char-sha>.md` — matching the findings
artifact's full-SHA policy. Short SHAs are forbidden (collision risk across
repos).

**Safe-write requirements** (matching Step 8 findings artifact):

- Symlink/reparse-point rejection on the target path before writing
- Atomic write: temp file + rename, never direct write to the final path
- No unsafe overwrite: if the target path already exists with a different
  `fixed_point` or `head_sha`, abort rather than overwrite

**Write-time freshness**: immediately before writing, re-resolve
`git rev-parse HEAD`. If it differs from the HEAD captured in Step 1, abort
(fail closed) — the evidence was computed against a HEAD that no longer
exists. This closes the race between evidence computation and artifact write.

**Read-only enforcement**: the code-reviewer and security-reviewer profiles
have no dedicated Edit or Write tools; Bash may exist but is not a sanctioned
write path. The artifact's integrity during fan-out relies on this
profile-level constraint, not filesystem permissions. The skill text does not
impose filesystem-level read-only because that is outside the instruction
surface.

**Lifecycle/retention**: the artifact is session-scoped. No mandatory cleanup
is imposed (matching the findings-artifact precedent). The parent may delete
the file after Step 7 verification completes. On CI runners, temp-directory
cleanup handles retention. The file contains branch names, commit messages,
and pre-pass results for unmerged work — parity with the findings artifact's
information scope.

## Deterministic ship-review to nested code-review handoff

When the rebase delta is **non-empty**, `/ship-review` invokes `/code-review`
with `Explicit diff range: <stage-9-cleared-commit>...HEAD` per
[ADR 0014](./0014-ship-review-reuses-code-review-for-the-rebase-delta.md). The
ship-review artifact is **not** an input to that nested `/code-review`
invocation. `/code-review` computes its own pre-pass (Steps 1–3a) internally
over the accepted explicit range and writes its own artifact. Step 3a records
that range in `diff_range`, sets `fixed_point` to the left side, and derives
the diff command and commit list from it. The two artifacts are
independent: each skill writes under its own path segment (`code-review/` vs
`ship-review/` beneath the repo-scoped root, e.g.
`<temp>/pr-review/<repo-hash>/code-review/pre-pass-<sha>.md` vs
`<temp>/pr-review/<repo-hash>/ship-review/pre-pass-<sha>.md`), so they cannot
collide even when both run at the same HEAD, and they have different fixed
points and different evidence. The
ship-review artifact serves only the Security and Coverage lanes.

When the rebase delta is **empty**, the ship-review artifact still contains
the `/verify` table and the named correctness confirmation. The Security and
Coverage lanes consume it; `/code-review` is not invoked.

The artifact must not replace the invocation-prompt field. Nested
`/code-review` creating its own pre-pass over the accepted
`Explicit diff range: <fixed-point>...HEAD` preserves
ADR 0014's correctness-lane scope.

## Rejected alternatives

**JSON format.** Less readable for LLM sub-agents; evidence includes tables
and diagnostics that render naturally as Markdown.

**Inline relay with truncation.** Still duplicates; truncation risks losing
context a sub-agent needs.

**Companion files checked into the skill directory.** Those are static
reference. The pre-pass artifact is computed per-review.

**Working-tree root.** Predictable naming plus gitignore lets a hostile branch
plant a passing artifact.

**Short SHA in filename.** Collision risk across repos. The findings artifact
uses the full 40-char SHA, and this artifact's naming must match.

## Accepted cost

Sub-agents must perform a file read as their first action, adding one tool
call per axis. The parent no longer carries the evidence in its own context
after dispatch, so it cannot re-check sub-agent work against the raw evidence
without re-reading the artifact.

## Consequences

Review fan-out stays parallel and isolated. Each axis reads the same scratch
file instead of receiving a parent-relayed copy of the computed evidence.
Smell baseline, standards-source list, and spec path remain inline because
they are not computed pre-pass evidence.

Stale or planted input is fail-closed: consumers verify repository, HEAD,
fixed point, and `diff_range`; writers re-resolve HEAD immediately before the
atomic write; working-tree roots are forbidden; filenames use a repo-scoped
full SHA under a skill-unique subdirectory.

`/ship-review` keeps ADR 0014's `Explicit diff range: <stage-9-cleared-commit>...HEAD`
for nested `/code-review`. A non-empty delta produces two independent artifacts. An empty
delta does not invoke `/code-review`.

This is a runtime contract. It does not change adapters, `install.ps1`,
install tests, or lint grep gates. The Step 8 findings-artifact phrase
`findings artifact as JSON` remains the output sink and is out of scope.
