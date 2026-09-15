# dotnet-agent-harness (this repository)

This file is for **working on the harness itself**. It is not the consumer
`CLAUDE.md` that `install.ps1` writes into adopting repos (that template lives
under `adapters/claude/CLAUDE.md`).

## Task intake in this repo

Work on this repository is driven by a Maestri team, not by the harness's own
pipeline. **Do not invoke the harness's analysis and pipeline skills on this
repository**: `/grill-with-docs`, `/implement`, `/code-review`, `/refactor`,
`/verify`, `/architect`, `/ship-review`, and the speckit commands. They are
built for C#, and this repository contains none outside `fixtures/BadCode/`,
which is deliberately broken and must never be edited. Running them here costs
tokens and returns nothing. Do the work directly.

After DEV-113, `/code-review` is C#-evidence only
([ADR 0022](docs/adr/0022-harness-targets-csharp-only.md)). This repository has
no production C#, so it cannot self-review with `/code-review` — the skill would
refuse the diff as **out of scope for this skill**. Review harness changes with
the PowerShell tests under `scripts/local/` and the grep gates in
`.github/workflows/lint-harness.yml`, plus human reading. There is no generic
fallback reviewer.

There is no `dotnet-tools.json` and no solution to restore or build. The gates
that matter are the PowerShell tests under `scripts/local/` and the grep gates
in `.github/workflows/lint-harness.yml`.

Issue intake here is manual — two commands, no skill. This repository's
Maestri/self-development workflow stays on GitHub Issues; consumer `/task`
intake is tracker-neutral and is not used here.

```powershell
./packs/dotnet/scripts/new-task-branch.ps1 -Issue <n> [-Type feature|bug|hotfix]
pwsh ./scripts/local/Set-IssueInProgress.ps1 -Issue <n>
```

The first creates the branch and its worktree under
`../dotnet-agent-harness.worktrees/`; a dirty main checkout does not block it,
which is what lets several agents work this repo at once. If the branch already
exists, stop and report — do not force.

The second discovers the issue's project items at runtime and sets Status to
In Progress only when it is currently empty, `Todo`, or `Backlog`. It leaves
`Done` and mid-flight statuses alone, and warns and exits 0 when the issue is on
no board. Requires `gh` with the project scope: `gh auth refresh -s project`.

Intake stops there. There is no grill step and nothing to `dotnet tool restore`.

## This repository has no skill discovery trees

`skills/` and `.claude/agents/` are **authored sources that ship to consumers**.
They are not commands you can invoke here. The harness no longer projects them
into `.claude/skills/` or `.agents/skills/`, so `/implement`, `/code-review`,
`/verify` and the rest do not resolve in this checkout. That is deliberate — see
[ADR 0012](docs/adr/0012-the-harness-does-not-project-its-own-skills.md).

Edit the canonical files under `skills/` directly. To see how one renders for a
consumer, run `install.ps1` against a scratch repository.

If a harness command still resolves here, it is coming from an installed plugin
rather than from this repository. The rule above still applies: do not run it on
this repo.

## If you are the Conductor of a Maestri team

You coordinate; you do not implement. Task intake, branch creation, worktrees
and commits belong to the **Operator** seat. Plan approval and acceptance
belong to the **Thinker** seat. Before doing repository work yourself, run
`maestri list` and delegate it. Doing a seat's work yourself is the failure
mode the team exists to prevent.

## Which host and model to run a command on

The live seat map is Maestri workspace state at `~/.maestri/workspaces/<workspaceId>/seat-map.json` (resolved lazily from the active workspace; an explicit `-SeatMapPath` still overrides). It defines host and tier allocation for team seats, ordered best first (`head`, `then`, `floor`), with a **floor** marking the lowest option that still does the work without losing quality. `scripts/local/seat-map.example.json` is the schema, the invariants block, and the CI contract.

```powershell
pwsh ./scripts/local/Sync-SeatMap.ps1 -Validate
```

Read down the chain to the first option you still have allowance for. **If that lands below the
floor, the work waits**; running below it means knowingly accepting reduced
quality, which is the one thing the seat map exists to make visible.

`scripts/local/Test-ModelProbe.ps1` auditions a candidate model on a named host against the floor-model probe kit (G1 trap, per-seat bars, cost ladder) and writes the resulting cell into the live workspace seat map. `Test-ModelProbe.ps1` launches hosts and can bill; use `-WhatIf` for non-launching validation.

```powershell
pwsh ./scripts/local/Test-ModelProbe.ps1 -Host cursor -Model composer-2.5 -Test Verdict -Seat conductor -Rung floor -WhatIf
```

Running a probe without `-WhatIf` launches the model host and updates the live workspace seat map:

```powershell
pwsh ./scripts/local/Test-ModelProbe.ps1 -Host cursor -Model composer-2.5 -Test Verdict -Seat conductor -Rung floor
```

The deviation log is retired. `route-log.jsonl`
remains on disk but is no longer part of the routine. The trial it served
concluded on 2026-09-08 (DEV-106), and its finding was that hand-annotated
logging does not survive contact with real work: two entries and no deviations in
a month. Routing corrections land in ADRs (such as ADR 0025) and in this file instead. Any future spend tracking has to
be cheaper to write than to skip, which is the constraint DEV-63 inherits.

See `docs/adr/0025-versioned-seat-map-and-canvas-portal.md` for seat map versioning details. Script tooling is not shipped by `install.ps1`. git history retains all prior values of scripts/local/seat-map.json; history rewriting is out of scope for DEV-239.

## OpenRouter via OpenCode

`openrouter` remains available as an allocation in the live workspace seat map for fast mechanical seats, for the reason argued in [ADR 0025](docs/adr/0025-versioned-seat-map-and-canvas-portal.md). Every other stage keeps its existing route.

Since 2026-09-14 OpenRouter is called through **OpenCode**, with Maestri
orchestrating the seats. See
[ADR 0024](docs/adr/0024-retire-junie-openrouter-launcher-for-opencode.md).

Configuration details to be documented when the operator confirms the current
OpenCode setup (DEV-233).
