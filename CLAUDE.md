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

There is no `dotnet-tools.json` and no solution to restore or build. The gates
that matter are the PowerShell tests under `scripts/local/` and the grep gates
in `.github/workflows/lint-harness.yml`.

Issue intake here is manual — two commands, no skill:

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

`scripts/local/Get-ModelRoute.ps1` recommends a host and tier for a pipeline
command, ordered best first, with a **floor** marking the lowest option that
still does the work without losing quality:

```powershell
pwsh ./scripts/local/Get-ModelRoute.ps1 -List
```

```powershell
pwsh ./scripts/local/Get-ModelRoute.ps1 -Command /implement -RepoRoot ../SomeRepo -Area frontend
```

It only advises — it never launches or configures anything. Read down the chain
to the first option you still have allowance for. **If that lands below the
floor, the work waits**; running below it means knowingly accepting reduced
quality, which is the one thing the map exists to make visible.

Record what you actually ran, especially when it differed:

```powershell
pwsh ./scripts/local/Add-RouteDeviation.ps1 -Command /implement -Ran junie:deep -Note 'Claude weekly limit hit'
```

Those deviations are the point, not an admission of failure — they are the
evidence for whether the authored judgments in `route-map.json` hold up. See
`docs/adr/0008-route-map-records-work-demands.md` for why the map records what
work demands rather than what models provide,
`docs/adr/0010-cheap-metered-lane-precedes-the-flat-rate-floor.md` for the one
row that spends metered capacity ahead of flat-rate, and
`specs/046-route-map-advisor/` for the reasoning behind each row. Neither script
is shipped by `install.ps1`.

## OpenRouter via Junie

`openrouter` is the first route for `/code-review` and `/ship-review` in this
checkout, and sits mid-chain as a cheap `fast` lane on the four mechanical
commands (`/task`, `/speckit-specify`, `/speckit-tasks`, `/gherkin`) — above the
flat-rate floor, for the reason argued in
`docs/adr/0010-cheap-metered-lane-precedes-the-flat-rate-floor.md`. Every other
stage keeps its existing route. The launcher uses `OPENROUTER_API_KEY` only in
the environment and resolves its model from the tier (table below); it does not
write the key to `.junie/`, the command line, or a repository file:

```powershell
pwsh ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier deep -Task 'Review the current diff on the Risk, Standards, and Spec axes.'
```

That example uses `-Tier deep`, matching `route-map.json`'s `/code-review`
entry. `/ship-review` routes to `-Tier balanced` instead:

```powershell
pwsh ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier balanced -Task 'Ship-review the current diff.'
```

Junie's `--model` accepts only built-in aliases or `custom:<profile-id>`; raw
OpenRouter ids are rejected client-side. The launcher therefore maintains a
custom profile per model under `~/.junie/models/openrouter-<model>.json` and
invokes Junie with `--model custom:<derived-name>`. The profile holds an
environment reference (`${OPENROUTER_API_KEY}`), never the key itself.
The task text is piped to Junie as JSON on stdin (`--input-format=json`) —
both to keep it off the command line and because Junie's `readPipedInput`
path crashes with `ERROR_INVALID_FUNCTION` ("Função incorreta") on Windows
when stdin is redirected without piped input. Still, do not put secrets in
`-Task`.

`fast`, `balanced`, and `deep` map to Junie's `low`, `medium`, and `high`
effort respectively, and each tier now resolves to its own default model
rather than all three sharing GLM 5.2. Prices below were verified live
against OpenRouter on 2026-08-25:

| Tier | Junie effort | Default model | Price per 1M in/out |
| --- | --- | --- | --- |
| fast | low | `deepseek/deepseek-v4-flash` | $0.077 / $0.154 |
| balanced | medium | `deepseek/deepseek-v4-pro` | $0.556 / $1.112 |
| deep | high | `z-ai/glm-5.2` | $1.190 / $3.740 |

`-Model` still overrides the tier default for a single run:

```powershell
pwsh ./scripts/local/Invoke-OpenRouterTask.ps1 -Tier balanced -Model qwen/qwen3-coder -Task 'Review this diff for regressions.'
```

`deep` stays on GLM 5.2, so the existing `/code-review` route is unchanged.
Escalate from the cheap `fast` lane to `deep`, or off OpenRouter entirely to a
flat-rate host, when the work needs judgment rather than mechanical edits.

The generated profile now carries `extraBody.provider.sort = "price"` so
OpenRouter picks the cheapest endpoint for the slug. `provider.max_price` is
not set as a default: it fails closed with an HTTP 404 when the cap is below
every endpoint's price.

Run the documented dry-run test without spending credits:

```powershell
pwsh ./scripts/local/Test-OpenRouterTask.ps1
```
