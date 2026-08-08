---
name: task
description: The entry point for any new task. Takes a GitHub issue number and (optionally) a branch type, reads the issue title/body via the gh CLI, creates a correctly-named branch off the latest default branch (feature/bug/hotfix) in its own git worktree so tasks and agents can run in parallel, then hands off to the mandatory /grill-with-docs alignment step. Also handles the rebase step before a PR. Use when the user gives an issue number, says "start task", "create a branch for", "new feature/bug/hotfix", or "rebase before PR".
---

# Task

The **first step of every task.** Turns a GitHub issue into a ready-to-work branch in its own git worktree, kicks off the mandatory alignment grill, and later keeps the branch current before a PR. Invoke this skill instead of calling the scripts by hand — it orchestrates them. Intake runs from the repo root; everything after it runs from the task worktree. The scripts need PowerShell 7 (`pwsh`).

## Parameters

```text
$ARGUMENTS
```

- **issue** — the GitHub issue number, e.g. `142`. Optional if a description is given directly.
- **type** (optional) — `feature` | `bug` | `hotfix`. If omitted, inferred from the issue's labels (a `bug` label → `bug`), defaulting to `feature`. Hotfix is always an explicit human call and is never inferred.

Typical invocation: `/task 142 feature`, or just `/task 142`.

## Prerequisites

The [`gh` CLI](https://cli.github.com), authenticated (`gh auth login`). No tokens, config files, or environment variables of your own — `gh` owns the credential.

The tracker is **optional**. With no issue to work from, pass a description straight through and everything below still applies:

```powershell
./scripts/new-task-branch.ps1 -Description "Add upload retry" -Type feature
```

## 1. Intake — read the issue

```powershell
gh issue view 142 --json number,title,body,labels
```

Use the title and body as the source of truth. If the user also supplied a description, prefer theirs only when they say so; otherwise use the issue title. This text seeds `specs/<feature>/brief.md` when the change goes through the Spec Kit pipeline.

## 2. Resolve the branch type

Use the `type` parameter when given; otherwise infer:

- **feature/** — new feature or enhancement
- **bug/** — bug fix
- **hotfix/** — urgent production fix

Infer from the issue's labels (`bug`/`defect` → `bug`) or the user's wording, defaulting to `feature`, and confirm if ambiguous. Hotfix is always an explicit human call.

## 3. Create the worktree (off the latest default branch)

```powershell
./scripts/new-task-branch.ps1 -Issue 142
# force the type:
./scripts/new-task-branch.ps1 -Issue 142 -Type bug
# override the description slug:
./scripts/new-task-branch.ps1 -Issue 142 -Description "Fix null ref on upload"
# create and push:
./scripts/new-task-branch.ps1 -Issue 142 -Push
# switch this checkout instead of creating a worktree:
./scripts/new-task-branch.ps1 -Issue 142 -NoWorktree
```

The script fetches `origin`, resolves the remote's default branch, branches from it, and names the branch `{type}/{issue}-{slug}`. It refuses to run over an existing branch.

By default the branch is created in **its own git worktree** at `<repo>.worktrees/{type}-{issue}-{slug}`, a sibling of the repo. **Everything after this step happens in that worktree** — `cd` into the path the script prints before writing any code, and run `dotnet tool restore` there, because each worktree restores its own tools.

Why a worktree: one checkout serialises tasks. A branch held by one agent blocks every other agent, and a dirty tree blocks intake entirely. Separate worktrees remove both limits, so a dirty main checkout is *not* an error in this mode — only under `-NoWorktree`, which switches the current checkout and keeps the old refusal.

Two things a fresh worktree does not inherit, because git does not carry gitignored files:

- **`harness.yml`** — the script copies it, and says so. Without it every configured threshold would silently revert to a harness default. If the main checkout has no `harness.yml`, the script warns that the worktree runs on defaults; that warning is not noise.
- **`.specify/`** — Spec Kit is a runtime dependency, so run `specify init` in the worktree before any `/speckit-*` step. The script warns when the main checkout has it and the worktree does not.

When the PR merges, clean up: `git worktree remove <path>`.

## 4. MANDATORY: grill the development

Once the worktree exists — working inside it from here on — **immediately run `/grill-with-docs`** — do not jump to a spec or code first. This is the essential "question the development" step: it interrogates the task (using the fetched issue title and body as raw input), settles vocabulary in `CONTEXT.md`, records any ADRs, and produces `specs/<feature>/brief.md`. The spec (`/speckit-specify`) is written from that settled output.

Do not proceed past this step until the grill concludes with shared understanding. For a tiny bug fix the grill is short — but it still happens.

## 5. Commit convention

Reference the issue in every commit **subject** so GitHub links the work:

```
Add dark mode toggle (#142)
```

The reference is a **suffix, not a prefix**: a subject beginning with `#` is treated as a comment by git's editor-based commit path and gets silently stripped. GitHub auto-links `#142` anywhere in the message.

(Only commit when the user asks — the standard git safety rules still apply.)

## 6. Before a PR — rebase

Always bring the branch up to date so anything merged in the meantime is included:

```powershell
./scripts/rebase-task-branch.ps1 -Push
```

This fetches and rebases onto the remote default branch, then pushes. On conflicts it stops with next steps (`git rebase --continue` / `--abort`) — resolve, then re-run. The push forces with `--force-with-lease` only when the rebase rewrote history the remote branch already holds; a first push (no remote branch yet) is a plain `--set-upstream` push, so it does not trip a force-push guard. Only open the PR after a clean rebase and push.

## Rules

- After the branch is created, `/grill-with-docs` is **mandatory** before any spec or code — never skip straight to `/speckit-specify` or implementation.
- Work in the worktree the script created, not the main checkout. Editing the main checkout puts the change on whatever branch that checkout happens to hold.
- Never create worktrees inside the repo. Git keeps them out of `git status`, but `dotnet build`, InspectCode, and every recursive glob still walk them, so one task's checkout lands in another task's gate results.
- Never branch from a stale local default branch — always from `origin/<default>` (the script fetches first).
- Never open a PR without rebasing first.
- Preserve the issue reference in both the branch name and every commit subject.
- Never open or push a PR automatically — that is a human decision at gate 3.

## Related

- `/grill-with-docs` — the mandatory next step
- `/pipeline` — where this sits in the stage order (stage 0)
- The `github-workflow` rule — the always-on version of these conventions
