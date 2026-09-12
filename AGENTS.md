# dotnet-agent-harness (this repository)

This file is for **working on the harness itself** under Codex. It is the
counterpart of the root `CLAUDE.md` — not the consumer `AGENTS.md` that
`install.ps1` writes into adopting repos. That template lives at
`adapters/codex/AGENTS.md`; keep the two separate, because this file describes
*developing* the harness and that one describes *consuming* it.

`install.ps1` installs `AGENTS.md` skip-if-exists
([ADR 0001](docs/adr/0001-codex-adapter-distills-rather-than-imports.md)), so no
installer run rewrites this file.

## GitHub writes

For GitHub write operations in this repo — posting PR reviews/comments, creating
or updating PRs/issues, requesting reviewers, labels, or project changes — do not
use the GitHub connector. Use the authenticated `gh api` CLI path instead. The
GitHub connector may still be used for read-only metadata, diff, and discussion
lookups.

## Task intake in this repo

Work on this repository is driven by a Maestri team, not by the harness's own
pipeline. **Do not invoke the harness's analysis and pipeline skills on this
repository**: `grill-with-docs`, `implement`, `code-review`, `refactor`,
`verify`, `architect`, `ship-review`, and the speckit commands. They are built
for C#, and this repository contains none outside `fixtures/BadCode/`, which is
deliberately broken and must never be edited. Running them here costs tokens and
returns nothing. Do the work directly.

After DEV-113, `code-review` is C#-evidence only
([ADR 0022](docs/adr/0022-harness-targets-csharp-only.md)). This repository has
no production C#, so it cannot self-review with `$code-review` — the skill would
refuse the diff as **out of scope for this skill**. Review harness changes with
the PowerShell tests under `scripts/local/` and the grep gates in
`.github/workflows/lint-harness.yml`, plus human reading. There is no generic
fallback reviewer.

There is no `dotnet-tools.json` and no solution to restore or build. The gates
that matter are the PowerShell tests under `scripts/local/` and the grep gates
in `.github/workflows/lint-harness.yml`.

Issue intake here is manual — two commands, no skill:

```powershell
./packs/dotnet/scripts/new-task-branch.ps1 -Issue <n> [-Type feature|bug|hotfix]
pwsh ./scripts/local/Set-IssueInProgress.ps1 -Issue <n>
```

The first creates the branch and its worktree under
`../dotnet-agent-harness.worktrees/`. The second sets the board Status to
In Progress only when it is currently empty, `Todo`, or `Backlog`, and warns and
exits 0 when the issue is on no board. Requires `gh` with the project scope:
`gh auth refresh -s project`.

Intake stops there. There is no grill step.

## This repository has no skill discovery trees

`skills/` and `.claude/agents/` are authored sources that ship to consumers, not
commands. The harness no longer projects them into `.agents/skills/`, so
`$implement`, `$code-review` and the rest do not resolve here. That is
deliberate — see
[ADR 0012](docs/adr/0012-the-harness-does-not-project-its-own-skills.md), which
supersedes [ADR 0003](docs/adr/0003-codex-skills-use-a-generated-agents-copy.md)
for this repository only. ADR 0003 still governs what `install.ps1` generates in
a consumer repo.

Read the canonical files under `skills/` directly and edit them in place. To see
how one renders for Codex, run `install.ps1` against a scratch repository.

## Always-on rules are not auto-loaded here either

A consumer install distils the three always-on rules into its own `AGENTS.md`
because Codex has no `@import` and a consumer has no other copy to read. The
eight scoped rules load through skills (and, on Cursor/Claude, glob/`paths`
matching). This repo authors those rules, so restating them here would add a
third copy that can go stale. Read them from the source when a task touches them:

- `rules/pipeline/*.mdc` — pipeline and convention rules (3 always-on; 5 glob-scoped; 3 skill-load)
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
