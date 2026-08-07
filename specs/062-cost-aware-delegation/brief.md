# Cost-aware agent delegation

Source: GitHub issue #62

## Problem

The harness documents `agents.tiers`, but canonical agent profiles do not declare
a tier and installation does not render tier settings into host-discoverable
profiles. The configuration is therefore inert. The runtime guidance also only
delegates at named pipeline stages, missing small mechanical errands whose raw
input is much larger than their returned answer.

Current delivery assumptions have drifted from the hosts: Cursor now discovers
project agents under `.cursor/agents`, Codex supports `.codex/agents/*.toml`, and
Claude Code's read-only control is `permissionMode: plan` rather than the
Cursor-specific `readonly` field.

## Shared understanding

- Keep one canonical profile per agent under the harness's `.claude/agents`
  source tree and generate host discovery copies during installation.
- Claude Code receives `.claude/agents/*.md`, Cursor receives
  `.cursor/agents/*.md`, and Codex receives `.codex/agents/*.toml`.
- Seven profiles ship: `gate-runner` and the new `code-scout` and
  `edit-applier` are `fast`; `test-writer`, `mutation-analyst`, and
  `code-reviewer` are `balanced`; `security-reviewer` is `deep`.
- Every host tier has nested `model` and `effort` settings. The old scalar
  Claude and Cursor shape is intentionally unsupported in 0.3.0.
- Default `fast` settings are Claude Code
  `claude-haiku-4-5-20251001`/`low`, Cursor `gpt-5.6-luna`/`low`, and Codex
  `gpt-5.6-terra`/`low`. `balanced` and `deep` inherit model and effort.
- Host projections use native syntax. Inherited fields are omitted where absence
  means inherit; Cursor renders `model: inherit`, and combines a pinned model and
  effort as `model-id[effort=low]`.
- Canonical read-only profiles project to `permissionMode: plan` for Claude,
  `readonly: true` for Cursor, and `sandbox_mode = "read-only"` for Codex.
- Generated files carry a harness ownership marker. Reinstallation refreshes
  marked files, preserves unrelated files, and reports rather than overwrites an
  unmarked same-name collision. Exact unmodified 0.2.0 Claude agent copies are
  adopted during migration; modified copies remain consumer-owned.
- Add an always-on delegation rule. A cheap errand is eligible only when its
  brief is short and complete, it is one-shot, the parent wants a compact answer
  rather than source material, and the raw input is much larger than the answer.
- Keep work inline when the parent needs the contents, one tool call suffices,
  context transfer is substantial, or the parent must re-read the source to
  trust the answer.
- Cheap errands may gather evidence but may not make semantic verdicts, feed a
  human gate or grilling conversation, or perform unspecified writes.
- `gate-runner` has a narrow mechanical exception: it may map command evidence
  to `Pass`, `Failure`, `Skipped`, or `Could not run` when it reports the command
  and exit code. It may not dismiss findings, judge equivalent mutants, or
  overrule tool evidence.
- A writable errand names an exact transformation and an exclusive file set.
  The parent does not edit those files until return, then reviews the diff.
  Parallel writable errands require disjoint file sets.
- If an errand is ambiguous, partial, or untrustworthy, retry inline once and do
  not re-brief it. If `edit-applier` already changed files, it stops and reports
  the exact partial diff; the parent reviews that state and finishes inline
  without automatic rollback.

## Constraints

- Preserve consumer-authored and unrelated agent profiles on every host.
- Never override Codex built-in agent names.
- Do not add a numeric delegation threshold or heuristic configuration key.
- Do not pin `balanced` or `deep` to a model on any host.
- Keep the runtime rule fully represented in the generated Codex `AGENTS.md`,
  because Codex does not import Cursor rule files.
- Keep canonical briefs host-neutral; host-specific configuration belongs to the
  renderer.
- Preserve ADR history: ADR 0006 supersedes only ADR 0003's obsolete named-agent
  consequence.

## Acceptance checks

- Every canonical profile declares a valid tier and every selected host receives
  the same seven names in its native discovery format.
- Rendered model and effort values match the selected tier and host, including
  inherited-field omission and Cursor's combined syntax.
- Read-only controls map correctly on all three hosts; writable profiles remain
  writable.
- A repeated install refreshes marked profiles without changing unrelated files.
- Same-name unmarked collisions are preserved and reported; exact 0.2.0 Claude
  copies are adopted while modified legacy copies are preserved.
- The strict configuration parser accepts every documented nested key and
  rejects the old scalar shape and unknown keys.
- Lint fails for a missing/invalid tier or a rendered profile that disagrees with
  its tier configuration.
- The delegation rule is always-on, appears in Codex's distilled instructions,
  and is referenced rather than duplicated by the agent-usage skill.
- Documentation describes seven profiles, eleven always-on rules, current host
  discovery paths, default costs, and the 0.3.0 configuration migration.
- Focused configuration and install-artifact tests plus the full harness lint
  workflow pass.

The runtime choice to delegate is prose guidance and cannot be proven by CI; the
pull request must state that limitation rather than imply behavioral coverage.
