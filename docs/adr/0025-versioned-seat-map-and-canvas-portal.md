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
4. `.maestri/roles/*/role.json`, `AGENTS.md`, and `CLAUDE.md` — model-chain
   lines and floor guidance in each role's instruction surfaces.

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
carries an ordered `rungs` array of declared named rungs — each a complete
launch specification. Typical names include `head`, `then`, `alt`, and
`floor`; extra declared names are valid.

```json
{
  "name": "head",
  "role": "head",
  "launch": "claude --model claude-opus-4-6 --effort high --permission-mode auto",
  "pool": "CLAUDE",
  "tier": 3,
  "evidence": "measured",
  "host": "claude",
  "model": "claude-opus-4-6"
}
```

Rung names match `^[a-z][a-z0-9-]{0,30}$` and are unique per seat. Optional
fields are `tier`, `evidenceDate`, `cost`, and `role` (`role` is required
only on the head and floor rungs). Model-chain rendering walks array order
and ends with exactly one terminal `(FLOOR).` marker on the floor rung.

`schemaVersion` 1 fixed-object maps (`rungs.head` / `rungs.then` /
`rungs.floor`) fail closed with a diagnostic that names schemaVersion 2
and the migration requirement. DEV-235 does not migrate in place.

The `tier` field (0–4) records the pool's place in the operator's consumption
order. **Amended 2026-09-16:** the original 1–4 table (1 free, 2 expiring
allowances, 3 flat-rate, 4 metered) is replaced by the order the operator
actually spends in, which puts the generous flat-rate pools first and the free
pool last. The example map's rungs are renumbered to this scheme; the live map
is the operator's to renumber. Runtime FLOOR selection still requires a
numeric tier 1–4 on measured/cleared candidates; tier 0 (free/Zen) is never
selected as runtime FLOOR.

| Tier | Category | Examples |
|------|----------|---------|
| 1 | Generous flat-rate | Claude haiku, Codex `gpt-5.6-luna`, Cursor grok/composer, AGY gemini |
| 2 | Limited flat-rate | Codex gpt < 5.5, Cursor other-models, AGY claude/gpt |
| 3 | Metered, monthly-refilling | Gemini API credit, JetBrains AI Pro (Junie) |
| 4 | Metered, out of pocket | OpenRouter wallet, DeepSeek wallet |
| 0 | Free | Zen free pool, OpenRouter `:free` endpoints |

Consumption order is 1 > 2 > 3 > 4 > 0. The order and the per-pool preferences
are recorded in the map itself as `invariants.tierPolicy` (consumption order,
pool and model tiers, per-pool model reservations, per-pool active-seat caps,
seats a pool must not carry, preferred head pool per seat, and seat/pool pairs
observed to misbehave). The validators read that block and print **advisory
warnings** — `TIER`, `ORDER`, `MODEL`, `SEAT`, `AVOID`, `HEAD`, `POOL` — that
never change the exit code: the operator may run any model on any seat, and the
map's job is to say when a choice crosses a stated preference, not to refuse
it. A map without `tierPolicy` yields no warnings.

The `evidence` field records probe status: `measured` (passed the ACCEPT/REJECT
trap probe), `cleared` (passed a lighter bar), `probed` (took the probe but
evidence is partial), or `unmeasured`.

### Charter invariants are contract-tested

`Test-SeatMap.ps1` validates the schema and enforces the invariants from the
seat charter. It runs against `scripts/local/seat-map.example.json` (the
contract); the live map is workspace state under `~/.maestri/workspaces/<id>/`
and is not a CI artefact:

- At most 2 Cursor-pool heads.
- At most 1 AGY-G-pool head.
- At least 1 Gemini-API-pool head.
- ZEN is never a floor pool (Quill is the documented exception).
- Every seat's declared rungs use distinct pools.
- Every OpenCode launch line contains `-m` or `--model` (the shared-config trap).
- Tier values, when present, are integers 0–4 (runtime FLOOR selection still requires 1–4).

This gate is defined in `lint-harness.yml` on both Windows and Ubuntu behind
`vars.RUN_LOCAL_SELF_TESTS == 'true'` (DEV-260 parked it while DEV-253-259
relocates the tooling; it no longer runs on every push by default). It replaced
the `Test-RouteMap.ps1` gate (DEV-64).

### A 4-way synchronizer propagates changes

`Sync-SeatMap.ps1` reads the live workspace seat map (or an explicit
`-SeatMapPath`) and writes the four downstream targets:

1. Role instruction surfaces (`.maestri/roles/*/role.json`,
   `.maestri/roles/*/AGENTS.md`, and `.maestri/roles/*/CLAUDE.md` — the
   model-chain line and floor guidance).
2. `notes/harness-team-charter.md` (the Roster table).
3. `notes/team-restart.md` (the Launch commands table).
4. Terminal replacement commands (`maestri recruit --replace`).

`-Validate` checks the seat map against the same charter invariants and exits 1
on any violation, so the merge bar can prove the synchronizer would not propagate
invalid state. Path resolution is lazy: an empty `-SeatMapPath` is resolved
after helpers load, so a missing workspace degrades to a missing-file message
rather than a bind-time throw.

Targets 2–4 are Maestri canvas notes and terminal state, not tracked files.
They cannot be CI-proved. The synchronizer writes them at runtime; when
`RUN_LOCAL_SELF_TESTS` is enabled, CI proves only that the example seat map
itself is valid and that `-Validate` enforces the invariants.

`-Verify` is a read-only drift check (DEV-237). It validates the seat map
first, then compares each seat's **head-rung** launch to the terminal command
in `workspace.json` for the same `roleId`/`assignedRoleId`. Terminals whose
`_0` has a command but no `assignedRoleId` are skipped; assigned terminals
that omit required fields stay fatal. It does not use `activeRung` or
runtime-floor substitution. Any failure exits 1. Workspace-level fatals —
unresolved workspace, missing or unreadable `workspace.json`, malformed
workspace payload, or zero parsed terminal records — stop before seat
comparison. Seat-level findings — drift, missing or duplicate terminal per
seat — are collected in `seatMap.seats` order, reported together, then one
final exit. Output is redacted (codename, roleId, hashes, and workspaceId;
no full profile or `workspace.json` paths). `-Verify` cannot be combined
with `-Seat`/`-Rung`; use `-All` for write/sync then verify. `-All` runs
the existing sync phases first, handles syncMisses (including
`Restore-SwapRollback`) before taking a verify exit, then verify; on verify
failure with no pending sync misses it prints
`Sync phases completed before verify failure; workspace drift remains.` and
exits 1. When `RUN_LOCAL_SELF_TESTS` is enabled, CI proves failure and success
behavior through `Test-SeatMapLive.ps1` with an isolated HOME fixture against
`seat-map.example.json`; a green fixture proves the repository contract, not
the operator's live workspace. Real `~/.maestri` verification is optional
machine-local operator proof, not a merge-bar item.

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

### Target-swap runtime floor anchoring

The floor rung (`role: "floor"`, last in the declared array) is the static
schema slot. It is not automatically the resolved runtime FLOOR after a
target swap. Under the 2026-09-16 consumption order, Zen (tier 0) is last
and never a floor; advisory `ORDER`/`TIER` warnings report rungs read out of
`consumptionOrder` without changing swap exit codes.

A **target swap** is `Sync-SeatMap.ps1 -Seat <seat> -Rung <declared-name>`
or the portal endpoint that applies the same swap. For that seat only, the
runtime FLOOR is resolved from the current declared candidate rungs:

1. Eligible evidence is exactly `measured` or `cleared`. `probed`,
   `unmeasured`, blank, or missing evidence is ignored.
2. Eligible candidates must have a numeric `tier` from 1 through 4. A
   measured/cleared rung with missing, blank, or non-numeric tier fails the
   swap with a named non-zero error. Tier 0 is skipped (not selected).
3. Eligible candidates must pass floor safety: no disallowed floor pool
   (ZEN, unless the seat is in `zenFloorExceptions`) and no selected FLOOR
   whose pool equals the seat's head-role pool.
4. Among remaining candidates, choose the lowest numeric tier. Ties break
   in floor-safe order: `floor`, then `then`, then other middle rungs, then
   `head`.
5. If no candidate remains, the swap fails before any write and names the
   seat plus the missing capable runtime floor.

On success, the role prompt model-chain FLOOR endpoint (last array entry)
uses that resolved launch. Active-launch outputs (recruit commands, charter
roster, team-restart, portal response) stay `activeRung` outputs; they use
the resolved runtime FLOOR only when the active rung is the floor-role
rung.

Non-swap whole-map commands (`-Validate`, `-All`, `-SyncRoles`,
`-SyncNotes`) keep their existing contract and must not fail merely because
an unrelated seat has no capable runtime floor. Broader probe-evidence
re-anchor across the map is DEV-244.

### Role instruction files are display artifacts (DEV-269, amended 2026-09-18)

**Amended 2026-09-18:** The live seat map remains the authority for seat
allocation, displayed model-chain order, active rung, and runtime FLOOR
selection. Role model-chain lines and the reachable role instruction files
(`.maestri/roles/*/role.json` prompt text, `.maestri/roles/*/AGENTS.md`, and
`.maestri/roles/*/CLAUDE.md`) are downstream
sync/display artifacts written by `Sync-SeatMap.ps1`; they are not
independent runtime model validators and must not instruct seats to halt
because the host-reported model is absent from that text. Seat-map schema
validation, runtime FLOOR selection, pool/tier advisory warnings, and
OpenCode `-m`/`--model` launch checks are unchanged.

Removing the obsolete role-text membership tripwire also removes that runtime
check. Model or provider drift after launch is not detected by DEV-269 and
must not be claimed as enforced.

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
head/then/floor object.** Originally rejected: the charter then defined exactly
three rungs with distinct semantics, and an array was treated as future work.
**Superseded:** schemaVersion 2 shipped declared-rung arrays. The fixed-object
shape (`rungs.head` / `rungs.then` / `rungs.floor`) is fail-closed. Extra named
rungs such as `alt` are valid. This is the current contract, not deferred work.

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
role-sync and note-sync silently no-op because the UUIDs do not match. Role
instruction files are display artifacts only; after DEV-269 they no longer
carry a runtime model-membership tripwire, so mid-session model drift is not
detected by role-text sync. This is accepted because the live map is workspace
state, not a CI artefact:
the schema and invariants are proven against `scripts/local/seat-map.example.json`
when `RUN_LOCAL_SELF_TESTS` is enabled; the scripts remain in-tree for local
runs. Synchronization is a convenience for the machine that runs the team. The live path is discovered from `~/.maestri/workspaces/<id>/`.

The portal's security model is session-token authentication over localhost. This
is weaker than mutual TLS or a Unix socket, but the threat model is cross-origin
requests from the developer's own browser, not network-level attackers. The
per-session token is sufficient for that threat and avoids the complexity of
certificate management for a developer tool.

`Test-SeatMap.ps1` validates schemaVersion 2 declared-rung arrays (unique
names, required head and floor roles, at least four rungs). Extra declared
rungs are in-contract; the gate still fail-closes schemaVersion 1 fixed-object
maps.

## Deferred follow-ups

Each is filed as a separate ticket before this PR merges. IDs are listed in the
PR body.

- **Pre-flight validations** — Junie `effortPerModel` existence check, OpenCode
  global reasoning-effort collision warning, Cursor `cli-config.json` collision
  detection.
- **Probe-evidence re-anchor (DEV-244)** — broader than target-swap runtime
  floor anchoring: re-anchor from probe evidence across seats, candidate-pool
  expansion, and schema/evidence changes. Out of scope for DEV-234.

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
