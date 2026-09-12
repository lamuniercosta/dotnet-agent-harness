# Harness analysis review targets C# only

Analysis review in this harness requires compiled C# evidence. Workflow skills
orchestrate stages without language knowledge. This repository cannot
self-review with `/code-review` because it has no production C#; harness
changes use deterministic gates plus human reading. A future non-C# review
skill reopens this decision rather than stretching `/code-review`.

## Context

`/code-review` Step 3 is C#/Roslyn-specific: the optional `cwm-roslyn-navigator`
pre-pass, `dotnet format --verify-no-changes`, `dotnet build`, and
new-versus-pre-existing analyzer separation. Invoking it on markdown, scripts,
or harness docs spent review budget with no compiled evidence and treated the
result as a normal review. DEV-113 freezes that skill as C#-evidence-only.

The repository-wide principle is that analysis review needs C# evidence. This
ticket's **enforcement** is `/code-review` only. Other analysis skills
(`/verify`, `/refactor`, `/architect`, `/diagnosing-bugs`,
`/improve-codebase-architecture`) remain C#/Roslyn-shaped and are unchanged
out of scope. Workflow skills (`/pipeline`, `/task`, `/grill-with-docs`,
`/ship-review`'s orchestration) stay language-agnostic.

## Decision

`/code-review` classifies the diff's file extensions after the minimal range
and file-list resolution needed to know what changed, and **before** Step 0
loop-term fail-closed and Step 2 blast-radius scoring. If the range itself
cannot be resolved, that remains **Could not run**.

A non-empty diff with zero `.cs` files is a normal **out of scope for this
skill** outcome, not a failed review. The skill skips pre-pass artifact
creation and Steps 4–7 fan-out, names the repo's deterministic gates as the
applicable path, and still emits Step 8's findings artifact with
`declined: true`, a non-null `decline_reason`, and `findings: []`. It does
not route to `/remediate`. There is no generic language fallback and no prose
blast-radius row.

When any `.cs` file is present, the existing C# path is unchanged: optional
Roslyn pre-pass, tooling gate, new-versus-pre-existing separation, axis
fan-out, and the ADR 0013 gate contract. Empty deltas still must not enter
`/code-review` ([ADR 0014](./0014-ship-review-reuses-code-review-for-the-rebase-delta.md)).
`/ship-review` distinguishes a clean nested `/code-review` artifact from a
declined/out-of-scope one and reports the correctness lane as out of scope
rather than silently clean.

`.cs` presence is the proxy by deliberate cost. Incidental, generated, or
fixture C# can force the C# path.

## Enforcement versus out of scope

**Enforced now:** `skills/code-review/` (process, evidence threshold, cap
disclosure), nested consumption in `skills/ship-review/SKILL.md`, stage-9
handoff wording in `rules/pipeline/agent-pipeline.mdc`, and the consumer and
root docs that describe C#-only analysis.

**Unchanged / out of scope:** non-C# review support, a generic gate resolver,
a prose blast-radius row, convergence/watch/try-fix redesign, and edits to
other analysis skills. Expanding those is a new decision.

## Accepted cost

Mixed diffs take the full C# path on extension presence alone. A docs-heavy
change that also touches one generated or fixture `.cs` file still runs
Roslyn, `dotnet format`, and `dotnet build`; on a repo with no buildable
solution that surfaces as a tooling line rather than a refusal. Classification
runs before loop terms, so a no-C# consumer is not failed-closed for a missing
`brief.md` that a C# review would still require.

## Expansion path

A second review skill for prose, scripts, or another language reopens this
ADR. Until then, those diffs use the repo's deterministic gates plus human
reading.

## Consequences

The ADR 0013 gate contract still travels with the skill on the C# path.
Companion briefs keep an evidence threshold and an explicit cap of 15 with
cut disclosure. This repository's self-review path remains the PowerShell
tests under `scripts/local/` and the grep gates in
`.github/workflows/lint-harness.yml`, not `/code-review`.
