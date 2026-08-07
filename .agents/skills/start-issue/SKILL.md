---
name: start-issue
description: >-
  Repo-local wrapper around harness task intake for this repository only. Takes
  a GitHub issue number and optional branch type, runs the same intake/branch
  flow as task, then moves the issue to In Progress on every GitHub Project
  board item whose Status is empty, Todo, or Backlog. Warns and continues if the
  issue is on no project. Use when starting work from a GitHub issue in this
  repo. Not shipped by install.ps1 — this is the Codex entry point for the
  authored skill under .claude/skills/start-issue/.
---

# Start issue (repo-local, Codex entry point)

**Customization for `dotnet-agent-harness` only.** Codex discovers skills under
`.agents/skills/` and invokes them as `$name`; it does not scan `.claude/skills/`
([ADR 0003](../../../docs/adr/0003-codex-skills-use-a-generated-agents-copy.md)).
This directory exists so `$start-issue` resolves under Codex.

Unlike every other directory under `.agents/skills/` in a consumer repo, this one
is **hand-authored, not generated** — `install.ps1` copies only the canonical
`skills/` tree, and `start-issue` is deliberately outside it.

## The procedure lives in one place

Read [`.claude/skills/start-issue/SKILL.md`](../../../.claude/skills/start-issue/SKILL.md)
and follow it. That file is the authored source; this one is a pointer so the two
cannot drift. If they ever disagree, the `.claude/` copy wins — say so rather than
picking one silently.

Do not re-derive the board logic from scratch. Step 2 of that procedure calls
`scripts/local/Set-IssueInProgress.ps1`, which discovers project and Status field
IDs at runtime; reimplementing it ad hoc is a defect.

## Codex deltas when following it

The authored file is written in Claude Code's idiom. Three substitutions apply:

- **`/name` is not invocable here.** This repo has no generated `.agents/skills/`
  copy of the canonical tree, so `/task` and `/grill-with-docs` do not resolve as
  commands. Read `skills/task/SKILL.md` and `skills/grill-with-docs/SKILL.md`
  directly and follow them as written.
- **Pack paths, not consumer paths.** The branch script is
  `./packs/dotnet/scripts/new-task-branch.ps1` in this repo, not
  `./scripts/new-task-branch.ps1`.
- **The work happens in a worktree.** Intake creates
  `../dotnet-agent-harness.worktrees/{type}-{issue}-{slug}` and everything after it
  runs there. A dirty main checkout does not block intake, which is what lets a
  Codex session and a Claude session work this repo at the same time.
- **Named `.claude/agents/` profiles are unavailable.** Codex does not load them.
  Give a generic subagent the profile's brief inline, or do the work inline and
  disclose the fallback.

The mandatory grill in step 3 is not optional under Codex either.

## Parameters

```text
$ARGUMENTS
```

- **issue** — GitHub issue number, e.g. `41`
- **type** (optional) — `feature` | `bug` | `hotfix`

Typical: `$start-issue 41` or `$start-issue 41 feature`

## Prerequisites

`gh` authenticated with the **project** scope — the default login usually lacks it:

```bash
gh auth refresh -s project
```

PowerShell 7 (`pwsh`) for the board script and the harness branch scripts.
