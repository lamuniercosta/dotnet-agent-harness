# Canonical agent profiles generate host discovery copies

Agent profiles need the same brief on Claude Code, Cursor, and Codex, but the
hosts discover different directories and use different configuration syntax.
Treating any one installed host format as the source would either exclude a host
or create multiple authored copies that can drift.

## Decision

The harness authors each named agent once in its canonical `.claude/agents/*.md`
tree. Installation projects every canonical profile into the discovery format of
each selected host:

- Claude Code receives `.claude/agents/*.md`;
- Cursor receives `.cursor/agents/*.md`; and
- Codex receives `.codex/agents/*.toml`.

These installed files are generated discovery copies, not independent sources.
They keep the canonical agent name and brief while translating host-specific
fields. Read-only profiles render `permissionMode: plan` for Claude Code,
`readonly: true` for Cursor, and `sandbox_mode = "read-only"` for Codex. The
harness does not use names that override Codex built-ins.

Each canonical profile declares a host-neutral tier: `fast`, `balanced`, or
`deep`. Tier configuration supplies a `model` and `effort` for every host. A
value of `inherit` renders by omitting the field where the host supports an
absent-field fallback; Cursor's inherited model is rendered as `model: inherit`.
Host syntax remains deliberately asymmetric: for example, Cursor combines model
and effort in `model-id[effort=low]`, while Codex uses separate `model` and
`model_reasoning_effort` keys.

The default `fast` tier is pinned to the verified cheap option on each host:
Claude Code uses `claude-haiku-4-5-20251001` at low effort, Cursor uses
`gpt-5.6-luna` at low effort, and Codex uses `gpt-5.6-terra` at low effort.
The `balanced` and `deep` tiers inherit both settings. The older scalar Claude
and Cursor tier configuration is intentionally unsupported from version 0.3.0;
the changelog provides the nested-shape migration.

## Ownership

Every generated agent copy carries a harness ownership marker. Reinstallation
refreshes marked copies, preserves unrelated profiles, and leaves an unmarked
same-name file untouched while reporting the collision. During migration, an
unmarked legacy `.claude/agents` copy is adopted only when its contents exactly
match the harness 0.2.0 version; a modified copy remains consumer-owned.

This per-file ownership rule replaces blind directory copying for agent
profiles and preserves the installer promise that consumer-authored content is
not clobbered.

## Consequences

All three hosts can discover the same named agents without maintaining parallel
briefs. Tier selection becomes effective configuration rather than metadata, and
the generated outputs can be linted against the canonical profile set and tier
matrix.

The installer and tests must understand three output syntaxes, ownership markers,
legacy adoption, and collision reporting. Consumers with the old scalar tier
shape must migrate when upgrading to 0.3.0.

This decision supersedes only ADR 0003's statement that named profiles are not
copied. ADR 0003's generated-skill decision remains in force.
