# dotnet-agent-harness (this repository)

This file is for **working on the harness itself**. It is not the consumer
`CLAUDE.md` that `install.ps1` writes into adopting repos (that template lives
under `adapters/claude/CLAUDE.md`).

## Task intake in this repo

When starting work from a GitHub issue **in this repository**, use
**`/start-issue <n> [type]`** instead of `/task`.

`/start-issue` is a repo-local skill (`.claude/skills/start-issue/`) that:

1. Runs the same intake/branch flow as harness `/task`
2. Moves Portfolio (and any other board the issue is on) Status → In Progress
   when the current status is empty, Todo, or Backlog
3. Hands off to mandatory `/grill-with-docs`

It is **not** shipped by `install.ps1`. Consumers keep using `/task`.

Requires `gh` with the project scope: `gh auth refresh -s project`.

## Bootstrap canonical skills for self-development

The tracked discovery trees contain only the repo-local `start-issue` authored
overrides. Generate ignored discovery copies for every canonical harness skill:

```powershell
pwsh ./scripts/local/Sync-SelfSkills.ps1
```

The command uses the same Claude and Codex rendering paths as consumer
installation. It refreshes only manifest-owned copies, preserves `start-issue`
and foreign skills, and fails before mutation on an unowned same-name collision.
Reload Claude Code after syncing before expecting new `/name` commands to
resolve. Continue to prefer `/start-issue` over `/task` for issue intake here.

Remove only generated self-development copies with:

```powershell
pwsh ./scripts/local/Sync-SelfSkills.ps1 -Clean
```

This is not a full self-install; `install.ps1` still refuses the harness root.

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
