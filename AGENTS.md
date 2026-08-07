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

## Bootstrap canonical skills for self-development

The repository tracks only the canonical `skills/` sources and the repo-local
`start-issue` authored overrides. Generate the ignored host discovery copies
when you need to invoke the rest of the harness surface while developing it:

```powershell
pwsh ./scripts/local/Sync-SelfSkills.ps1
```

The command projects the Claude form into `.claude/skills/` and the Codex form
into `.agents/skills/` using the same renderer as consumer installation. It
refreshes and removes only names recorded in its ignored ownership manifest;
`start-issue` and foreign skills are never owned. An unowned same-name collision
fails before mutation instead of silently replacing a local skill.

Codex does not reload project skills during a running session. Restart or reload
Codex after sync before expecting `$verify`, `$implement`, or another newly
generated command to resolve. Use this repository's `$start-issue`, not `$task`,
for GitHub issue intake so project status handling remains active.

To remove the generated discovery copies without touching authored or foreign
skills:

```powershell
pwsh ./scripts/local/Sync-SelfSkills.ps1 -Clean
```

This bootstrap does not relax `install.ps1`'s full self-install refusal and does
not install gates, hooks, templates, or consumer configuration into this repo.

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
