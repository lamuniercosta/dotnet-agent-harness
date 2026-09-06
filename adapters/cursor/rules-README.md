# `.cursor/rules/` — read by **both** editors

Installed by `dotnet-agent-harness`. Do not delete this directory even if you
never open Cursor.

## Why a Claude-only project still has one

The three always-on rules here exist in exactly one place, and `CLAUDE.md` reaches
them by import:

```
@.cursor/rules/agent-pipeline.mdc
@.cursor/rules/delegation.mdc
@.cursor/rules/documentation-sources.mdc
```

Five C# gate rules load via `globs:` when `.cs` files are touched. Three
procedure rules (`github-workflow`, `readme-maintenance`, `architect-gate`) load
via skill invocation, not as always-on imports.

Cursor can only auto-load rules from `.cursor/rules/`, and a Claude `@import`
resolves any relative path — so the three always-on copies here serve both,
while a copy in each tree would be two files free to drift. Claude Code also
receives the eight scoped pipeline rules under `.claude/rules/pipeline/` (with
`paths:` on the five C# gates) so those auto-load without `@import`.

**Deleting this directory silently breaks all three always-on imports.** Nothing errors; the
rules just stop arriving, and the symptom is "the agent ignores our conventions".

## What's in here

| Path | Loaded by |
|---|---|
| always-on `*.mdc` (3) | Cursor natively; Claude Code via `CLAUDE.md` imports |
| glob-scoped `*.mdc` (5) | Cursor via `globs:`; Claude Code from `.claude/rules/pipeline/` using `paths:` |
| skill-load `*.mdc` (3) | Skill invocation (not auto-loaded) |
| `vendor/*.md` | Cursor via `globs:`; Claude Code from its **own** copy at `.claude/rules/vendor/` using `paths:` |

`vendor/` is the one thing written twice, because Cursor does not read
`.claude/rules/` and the two platforms use different frontmatter keys with
different semantics. Both copies are regenerated on every install — edit
`rules/vendor/` in the harness, not either copy here. The eight scoped pipeline
rules follow the same two-copy pattern under `.claude/rules/pipeline/`.

## Editing

These files are **overwritten on every `install.ps1` run**. To change a rule,
change it in the harness repo and re-install. To add a project-specific rule,
create a new `.mdc` file the harness doesn't own — the installer only replaces
the files it ships.

Thresholds are not editable here: they render from `harness.yml`.
