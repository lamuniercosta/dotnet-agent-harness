# Versioned seat map and canvas portal

Supersedes [ADR 0008](0008-route-map-records-work-demands.md) and
[ADR 0010](0010-cheap-metered-lane-precedes-the-flat-rate-floor.md).

The command-keyed `route-map.json` introduced in ADR 0008 is replaced by a
seat-keyed `seat-map.json` (historical path: `scripts/local/seat-map.json`). The route map ordered pipeline commands by host and
tier; the seat map orders seats by candidate model, pool, and marginal cost.
The metered-lane exception argued in ADR 0010 is subsumed by the tier field on
every rung.

## Context

Four sources of truth diverged under Maestri multi-agent orchestration:

1. `route-map.json` — command-keyed, tier-keyed, no seat dimension.
2. `notes/harness-team-charter.md` — the Roster table, manually edited.
3. `notes/team-restart.md` — launch commands, manually edited.
4. `.maestri/roles/*/role.json` — model-chain lines in each role's system prompt.

The route map assumed one operator choosing a host for a pipeline command. Under
Maestri, eleven seats run concurrently, each with its own pool constraints and
model chain. The command axis became irrelevant — what matters is which seat runs
which model on which pool, not which pipeline command triggered it. Manual
editing across four files caused drift within a single task; on DEV-116 the
Verifier ran a model outside its chain because a restart note was stale.

## Decision

### A single seat-map replaces the route map

The live seat map at `~/.maestri/workspaces/<workspaceId>/seat-map.json` is
keyed by seat, not by command. `scripts/local/seat-map.example.json` is the
schema, the invariants block, and the CI contract. Each seat
carries a set of rungs (`head`, `then`, `floor`) — each a complete launch
specification:

```json
{
  "launch": "claude --model claude-opus-4-6 --effort high --permission-mode auto",
  "pool": "CLAUDE",
  "tier": 3,
  "evidence": "measured",
  "host": "claude",
  "model": "claude-opus-4-6"
}
```

The `tier` field (1–4) records marginal cost:

| Tier | Category | Examples |
|------|----------|---------|
| 1 | Free | Zen free pool, open-weights free endpoints |
| 2 | Expiring allowances | JetBrains AI Pro credits, Google AI Pro weekly AGY allowance |
| 3 | Flat-rate subscriptions | Claude Code Pro, Codex, Cursor auto pool |
| 4 | Metered pay-as-you-go | OpenRouter wallet, Gemini API Tier 1 |

The `evidence` field records probe status: `measured` (passed the ACCEPT/REJECT
trap probe), `cleared` (passed a lighter bar), `probed` (took the probe but
evidence is partial), or `unmeasured`.

### Charter invariants are tested in CI

`Test-SeatMap.ps1` validates the schema and enforces the invariants from the
seat charter. CI runs it against `scripts/local/seat-map.example.json` (the
contract); the live map is workspace state under `~/.maestri/workspaces/<id>/`
and is not a CI artefact:

- At most 2 Cursor-pool heads.
- At most 1 AGY-G-pool head.
- At least 1 Gemini-API-pool head.
- ZEN is never a floor pool (Quill is the documented exception).
- Every seat's three rungs use distinct pools.
- Every OpenCode launch line contains `-m` or `--model` (the shared-config trap).
- Tier values, when present, are integers 1–4.

This gate runs in `lint-harness.yml` on both Windows and Ubuntu. It replaces the
`Test-RouteMap.ps1` gate.

### A 4-way synchronizer propagates changes

`Sync-SeatMap.ps1` reads the live workspace seat map (or an explicit
`-SeatMapPath`) and writes the four downstream targets:

1. Role prompts (`.maestri/roles/*/role.json` — the model-chain line).
2. `notes/harness-team-charter.md` (the Roster table).
3. `notes/team-restart.md` (the Launch commands table).
4. Terminal replacement commands (`maestri recruit --replace`).

`-Validate` checks the seat map against the same charter invariants and exits 1
on any violation, so the merge bar can prove the synchronizer would not propagate
invalid state. Path resolution is lazy: an empty `-SeatMapPath` is resolved
after helpers load, so a missing workspace degrades to a missing-file message
rather than a bind-time throw.

Targets 2–4 are Maestri canvas notes and terminal state, not tracked files.
They cannot be CI-proved. The synchronizer writes them at runtime; CI proves
only that the example seat map itself is valid and that `-Validate` enforces the
invariants.

The swap log at `~/.maestri/seat-map-swaps.jsonl` is per-workspace-keyed history
(`workspaceId` on each entry). git history retains all prior values of scripts/local/seat-map.json; history rewriting is out of scope for DEV-239.

### A localhost portal enables human swap

`Start-SeatMapServer.ps1` serves a browser UI on `http://localhost:8765` for
interactive seat-model swaps on the Maestri canvas.

**Security boundary.** The portal runs exclusively on localhost. CORS is
restricted to localhost origins. POST endpoints require a per-session token
generated at server start and embedded in the served HTML. This prevents
cross-origin requests from arbitrary pages open in the developer's browser
from triggering seat swaps (the finding that motivated this is adjudication
F6, sourced from Sentry R1).

**Validation.** Every write through the portal is validated against the same
charter invariants that `Test-SeatMap.ps1` checks before the seat map is
modified on disk. An invalid swap is rejected with the specific violation
reported in the UI.

**Audit.** Every `maestri recruit --replace` execution is logged to a local
swap-audit file with timestamp, seat, previous model, new model, and pool.
The log is untracked and machine-local.

### The floor is the cheapest capable model in each seat's pool

Each seat's `floor` rung is the lowest-tier model that has passed that seat's
evidence bar (`measured` or `cleared`). This is a structural property of the data
today — the floor rung always has the lowest tier value in each seat — but
**runtime floor anchoring** (logic that automatically re-selects the floor
after a swap or pool change) is deferred. The tier field makes it mechanically
checkable; the logic belongs in a follow-up.

### Legacy route-map tooling is deleted

Five tracked files are removed:

- `scripts/local/route-map.json`
- `scripts/local/Get-ModelRoute.ps1`
- `scripts/local/_route-map.ps1`
- `scripts/local/Test-RouteMap.ps1`
- `scripts/local/Add-RouteDeviation.ps1`

`route-log.jsonl` is untracked and gitignored. It is deliberately not deleted;
removing an ignored file from developer checkouts is more disruptive than
leaving it.

The `Test-RouteMap` step in `.github/workflows/lint-harness.yml` is removed and
replaced by the `Test-SeatMap` step (added in DEV-64, confirmed present on
origin/main).

References to `Get-ModelRoute`, `route-map.json`, and the `-Tier` examples in
root `CLAUDE.md` are replaced with seat-map equivalents.

`specs/046-route-map-advisor/` is historical spec documentation recording the
reasoning behind the original route-map rows. It stays in the tree.

## Rejected alternatives

**Keep the route map alongside the seat map.** The route map's command axis is
orthogonal to the seat axis, and some future orchestration might want both. But
maintaining two overlapping maps is the drift problem this change exists to solve.
Every consumer of the route map — `Get-ModelRoute.ps1`, the CLAUDE.md sections,
the CI gate — would need to be taught that the seat map supersedes it for any
seat-based work, and the two would diverge within a week. One source of truth
or none.

**Model the seat map as an extensible array of rungs instead of a fixed
head/then/floor object.** The ticket asks for ≥4 candidate options per seat.
An array schema would accommodate that directly. But the current charter defines
exactly three rungs with distinct semantics (head is the target, then is the
first fallback, floor is the cheapest capable), and `Test-SeatMap.ps1` validates
all three by name. An array loses named semantics and requires index-based
reasoning about which rung is which. The fixed object is extended to ≥4 when the
charter defines the semantics of a fourth rung, not before. This is a data +
schema change, not a data-only task (correcting the prior plan's claim).

**Run the portal on a non-localhost interface for remote team access.** The
portal executes `maestri recruit --replace` on the host machine. Exposing that
over the network turns a developer convenience into a remote code execution
surface. The portal stays localhost-only; remote access to seat configuration
uses the seat map file directly or the Maestri CLI.

**Enforce the floor-anchoring invariant at merge time.** The logic to
automatically re-anchor the floor to the cheapest capable model after a swap is
mechanically correct but has no test fixtures yet. Shipping untested anchoring
logic risks silently reassigning floors, and a wrong floor is the one failure
the tier system exists to prevent. The tier field ships now (making the invariant
checkable); the runtime logic ships when it has tests.

## Accepted cost

The live seat map embeds per-machine workspace state: role UUIDs from `.maestri/roles/` and,
at runtime, the active-rung selection. On any machine other than the author's,
role-sync and note-sync silently no-op because the UUIDs do not match. This is
accepted because the live map is workspace state, not a CI artefact:
CI proves the schema and invariants against `scripts/local/seat-map.example.json`, and synchronization is a convenience for
the machine that runs the team. The live path is discovered from `~/.maestri/workspaces/<id>/`.

The portal's security model is session-token authentication over localhost. This
is weaker than mutual TLS or a Unix socket, but the threat model is cross-origin
requests from the developer's own browser, not network-level attackers. The
per-session token is sufficient for that threat and avoids the complexity of
certificate management for a developer tool.

`Test-SeatMap.ps1` hardcodes the three rung names. Adding a fourth rung requires
editing the test, which means the test is a gate against accidental schema
expansion — a feature, not a bug, until the charter defines what a fourth rung
means.

## Deferred follow-ups

Each is filed as a separate ticket before this PR merges. IDs are listed in the
PR body.

- **Pre-flight validations** — Junie `effortPerModel` existence check, OpenCode
  global reasoning-effort collision warning, Cursor `cli-config.json` collision
  detection.
- **Workspace verification** — `Sync-SeatMap.ps1 -Verify` drift check against
  `workspace.json`. Included as a switch in the shipped script but not in the
  merge bar (machine-local state).
- **Candidate pool ≥4 expansion** — requires schema change from fixed object to
  named-rung array (or additional named properties), plus test and synchronizer
  updates.
- **Runtime floor anchoring** — logic that re-anchors the floor to the
  lowest-tier capable model after a swap or pool change. The tier field makes
  this mechanically checkable; the logic is deferred until test fixtures exist.

## Consequences

The route map's command axis is gone. Pipeline commands no longer have routing
advice; the seat assignment subsumes it. A seat that runs `/implement` uses
whatever model its head rung specifies, and the human operator chooses the seat's
model through the portal or by editing the seat map, not by consulting a
per-command table.

ADR 0008's principle — that the map records what work demands rather than what
models provide — survives in the evidence field. A model that has not been probed
carries `unmeasured` and cannot serve as a floor on a verdict-rendering seat.
The map still describes work fitness, just keyed by seat instead of command.

ADR 0010's metered-lane exception is subsumed by the tier field. Every rung
carries its marginal-cost tier explicitly, so the question "should metered
capacity precede flat-rate?" is answered per-rung rather than per-command. The
rule that flat-rate is spent first when tiers are equal is a human judgment
applied at swap time, not a schema enforcement.

The `specs/046-route-map-advisor/` directory stays in the tree as historical
documentation of the reasoning behind the original route-map rows. Its content
is no longer actionable but records the priors that informed this decision.
