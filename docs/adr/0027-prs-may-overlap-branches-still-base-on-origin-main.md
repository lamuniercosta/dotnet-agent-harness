# PRs may overlap; branches still base on origin/main

Concurrent open pull requests that touch the same paths used to fail the
ship-review rebase-delta self-test with `no open PR dependency or file
overlap for other PR heads`. That machine guard treated path intersection
across open PR heads as a dependency and a block. It was the only consumer of
`gh pr list` / `gh pr diff` in this repository's CI self-tests, and it had no
bot exemption: Dependabot pin bumps were indistinguishable from task PRs.

The same mutual deadlock appeared twice: #177/#178, then #179/#180. Historical
CI evidence (not re-runnable once both PRs merged):

- Run 35483490439 (PR #179) and run 35483493311 (PR #180), both legs failed
  with `FAIL  no open PR dependency or file overlap for other PR heads` and a
  detail naming the other PR on `.github/workflows/fixture-gates.yml`.

Live limitation: #179 and #180 are both MERGED (`gh pr list --state open` is
empty against current `origin/main`). The two-open-PR precondition no longer
exists, so the overlap leg cannot be exercised live and cannot reproduce that
historical failure. A green reduced-test run under zero open PRs does not by
itself prove the removal; source absence of the guard identifiers and policy
phrase is the proof. Do not invent throwaway PRs to re-stage the deadlock.

`adjudication-PR179-PR180-Keel-r1` ruled the guard correct and required
sequencing of #179/#180 (no CI guard correction for that pair). This ADR
records that the user's explicit decision to delete the open-PR overlap
policy **supersedes** that adjudication for future concurrent PRs: overlap is
no longer treated as a dependency or a procedural block.

## Decision

Remove the open-PR dependency/file-overlap guard entirely. Open-PR overlap is
not a dependency and is not a block. Multiple concurrent PRs and agents are an
intended Git workflow.

Rejected alternatives:

- Dependabot-only exemption
- Per-path allowlist
- Combining the conflicting PRs into one change

Preserved safety (unchanged by this decision):

- Branches still base on `origin/main` via `Ensure-OriginMainRef` and
  `Test-BranchBasedOnOriginMain`
- Freshness via `Test-OriginMainRefFreshness`
- Discriminated rebase-delta transport and the artifact consumer contract

Accepted costs:

- **Literal-gate limit.** The CI absence gate is a tripwire over source-file
  literals. A rename or reword can evade it, so a green gate is not proof of
  absence of an equivalent policy under another name.
- **Two-green-PR union window.** Two PRs each green against the same base may
  be merged in sequence; their union is never gate-proven. Mitigation remains
  pipeline section-9 rebase plus re-checks, and GitHub BEHIND status — not a
  machine overlap scan.

Honest stacking limit: `Test-BranchBasedOnOriginMain` is only
`merge-base --is-ancestor origin/main HEAD`. It does not detect stacking on a
feature branch. Stronger stacking detection is a separate task if wanted.

Follow-up for the generated Wisp role-record prompt (not delivered by this
repository change alone): YouTrack **DEV-278**, title "Remove open-PR overlap
block from generated Wisp role prompt", status Todo, repository
`dotnet-agent-harness`.

## Consequences

- `Test-NoOpenPrDependencyOverlap`, `Get-CurrentPullRequestIdentity`,
  `Get-OpenPrHeadRepositoryOwner`, and `Test-OpenPrIsCurrentPullRequest` are
  deleted from the ship-review rebase-delta helper; the reduced self-test no
  longer asserts open-PR non-overlap.
- Base, freshness, transport, and artifact-consumer checks remain, including
  fail-closed negatives for a divergent orphan HEAD and for a repo with no
  `origin` remote.
- Canvas procedural notes and the generated Wisp role prompt may still name
  overlap as a block until Conductor note amendments and DEV-278 land; this
  ADR states the intended policy now.
