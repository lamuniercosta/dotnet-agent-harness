# dotnet-agent-harness (this repository)

This file is for **working on the harness itself** under Codex. It is the
counterpart of the root `CLAUDE.md` — not the consumer `AGENTS.md` that
`install.ps1` writes into adopting repos. That template lives at
`adapters/codex/AGENTS.md`; keep the two separate, because this file describes
*developing* the harness and that one describes *consuming* it.

`install.ps1` installs `AGENTS.md` skip-if-exists
([ADR 0001](docs/adr/0001-codex-adapter-distills-rather-than-imports.md)), so no
installer run rewrites this file.

## Task intake in this repo

When starting work from a GitHub issue **in this repository**, use
**`$start-issue <n> [type]`** instead of `$task`.

`$start-issue` is a repo-local skill. Codex discovers it under
`.agents/skills/start-issue/`, which delegates to the authored procedure in
`.claude/skills/start-issue/SKILL.md`. It:

1. Runs the same intake/branch flow as harness `task`
2. Moves Portfolio (and any other board the issue is on) Status → In Progress
   when the current status is empty, Todo, or Backlog
3. Hands off to mandatory `grill-with-docs`

It is **not** shipped by `install.ps1`. Consumers keep using `$task`.

Requires `gh` with the project scope: `gh auth refresh -s project`.

## Harness skills do not resolve as `$name` here

Consumers receive the canonical `skills/` tree copied to `.agents/skills/`
([ADR 0003](docs/adr/0003-codex-skills-use-a-generated-agents-copy.md)). This
repository is the *source* of that tree, not a consumer of it, so it carries no
generated copy: `$task`, `$verify`, `$grill-with-docs` and the rest do **not**
resolve as commands here.

Read the canonical file directly instead — `skills/<name>/SKILL.md`, e.g.
`skills/verify/SKILL.md` — and treat the `/name` references inside skill text as
file paths under `skills/`, not as invocable commands.

Do not generate `.agents/skills/` copies of the canonical tree in this repo. That
would create a second authored copy of every skill, which is the drift the
harness exists to prevent. `.agents/skills/start-issue/` is the one deliberate
exception, because that skill exists only here and has no canonical source.

## Always-on rules are not auto-loaded here either

A consumer install distils the ten always-on rules into its own `AGENTS.md`
because Codex has no `@import` and a consumer has no other copy to read. This
repo authors those rules, so restating them here would add a third copy that can
go stale. Read them from the source when a task touches them:

- `rules/pipeline/*.mdc` — the always-on pipeline and convention rules
- `rules/vendor/*.md` — glob-scoped vendor rules

If this file and `rules/` ever disagree, `rules/` is the source and this file is
the stale one — say so rather than picking one silently.

## Paths differ from a consumer install

`install.ps1` flattens the .NET pack into a consumer's `scripts/`
(`packs/dotnet/scripts/install-gates.ps1`). In this repo those scripts stay at
their authored pack path, so a command copied out of skill text needs
translating before you run it here:

| In a consumer install | In this repository |
| --- | --- |
| `./scripts/new-task-branch.ps1` | `./packs/dotnet/scripts/new-task-branch.ps1` |
| `./scripts/run-*.ps1` (gates) | `./packs/dotnet/scripts/run-*.ps1` |
| `./scripts/hooks/` | `./hooks/` |

`./scripts/local/` is the exception: it is genuinely repo-local tooling for the
harness itself and is not installed anywhere.

## Limitations under Codex

The consumer template's [Limitations under Codex](adapters/codex/AGENTS.md)
section applies to sessions in this repo too — in particular, hooks are advisory
guardrails rather than an enforcement boundary, and **never ask Codex to read a
file containing a live credential**, because the secret scan cannot inspect a
credential read from a file. Rotate anything that reaches a model provider.
