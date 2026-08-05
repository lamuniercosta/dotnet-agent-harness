---
name: start-issue
description: >-
  Repo-local wrapper around harness /task for this repository only. Takes a
  GitHub issue number and optional branch type, runs the same intake/branch
  flow as /task, then moves the issue to In Progress on every GitHub Project
  board item that is not already Done. Warns and continues if the issue is on
  no project. Use when starting work from a GitHub issue and the issue should
  appear In Progress on Portfolio (or any other board it already belongs to).
  Not shipped by install.ps1 — lives under .claude/skills/, not packaged skills/.
---

# Start issue (repo-local)

**Customization for `dotnet-agent-harness` only.** Does not replace or fork the
shared harness `/task` skill. `install.ps1` syncs packaged `skills/` into
consumers; this directory is **not** in that tree, so it stays local.

## Parameters

```text
$ARGUMENTS
```

- **issue** — GitHub issue number, e.g. `40`
- **type** (optional) — `feature` | `bug` | `hotfix` (same rules as `/task`)

Typical: `/start-issue 40` or `/start-issue 40 feature`

## Prerequisites

- Authenticated `gh` (`gh auth login`), with permission to edit the project's Status field
- PowerShell 7 (`pwsh`) for `scripts/local/Set-IssueInProgress.ps1` and the harness branch scripts

## Steps

### 1. Run harness `/task` (or equivalent)

Follow [`skills/task/SKILL.md`](../../../skills/task/SKILL.md) exactly:

1. `gh issue view <n> --json number,title,body,labels`
2. Resolve branch type
3. `./packs/dotnet/scripts/new-task-branch.ps1 -Issue <n> [-Type …]` (from a consumer install the script is under `./scripts/`; in **this** repo the pack path is `./packs/dotnet/scripts/new-task-branch.ps1`)
4. Hand off to mandatory `/grill-with-docs` after the board step below — do not skip the grill

If the working tree is dirty or the branch already exists, stop and report; do not force.

### 2. Move project Status → In Progress

After a successful branch create (or if already on the correct task branch and the user only wants the board update):

```powershell
pwsh ./scripts/local/Set-IssueInProgress.ps1 -Issue <n>
```

Behaviour (do not reimplement ad hoc):

- Discover the issue's GitHub Project items at runtime (no hardcoded project IDs)
- For each item whose Status is **not** `Done`, set Status to **In Progress**
- If already `In Progress`, leave it and say so
- If the issue is on **no** project: **warn and continue** (exit 0) — do not block `/task` or the grill

### 3. Grill

Immediately run `/grill-with-docs` with the issue title/body as raw input (same as `/task` step 4).

## Rules

- Never put this skill under packaged `skills/` — that would ship it to every consumer via `install.ps1`
- Never invent project or Status field IDs; the script discovers them
- Never fail the whole start flow solely because the issue is missing from a board
- Do not open or push a PR; do not change Done items back to In Progress
- Commit subjects still follow harness `/task` (`… (#40)` suffix)

## Related

- `/task` — shared harness intake (source of truth for branch/grill)
- `./scripts/local/Set-IssueInProgress.ps1` — board update only
- `/grill-with-docs` — mandatory next step
