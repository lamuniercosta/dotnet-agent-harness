# Route map advisor

Source: GitHub issue #46

## Problem

Subscription quota is the binding constraint on build throughput, and it is
already scarce: two subscriptions past 70% of their weekly allowance and one
model pool exhausted for the month, with work outstanding. Deciding what to run
where is currently an unaided judgment made under pressure, at the moment the
cheap option is most tempting and its quality cost least visible.

Epic #26 answers this with a .NET 10 orchestrator across thirteen child issues.
That is too much to build before any of the benefit lands, and its routing model
is gated behind a benchmark campaign that does not exist yet.

Routing by role already ships: `install.ps1` resolves `agents.tiers` and stamps
`model` and `effort` into generated agent discovery copies. It reaches subagents
only. The interactive session — where `/implement` runs and most tokens go — is
whatever a human picked, and no artifact records which choice was right.

## Shared understanding

Add a repo-local advisor at `scripts/local/` that answers, for one pipeline
command, which host and tier to run it on. It prints a recommendation and does
nothing else.

- The routing unit is the command invoked (`/implement`, `/speckit-plan`), not
  the pipeline stage. Stage 2 alone spans five commands whose cost profiles
  differ enough that one answer is wrong for most of them.
- A route is a preference-ordered chain of host and tier options, best first,
  with a floor marking the lowest option that still does the work without losing
  quality. The head answers "best available", the floor answers "cheapest that
  suffices", and reading down to the first option with allowance remaining
  answers "what can I use right now".
- Reaching below the floor means the work waits. The advisor states this rather
  than recommending the next option down.
- The route map is committed JSON, holding one row per command with its chain,
  its floor, and a mandatory `why`. It names hosts and tiers, never models.
- Tiers resolve to models through `agents.tiers` in the target repo's
  `harness.yml`, read with the existing loader. A tier naming no model resolves
  to an explicit unpinned; the advisor does not guess.
- `-RepoRoot` selects which repo's `harness.yml` is read, so the advisor can be
  asked from anywhere about a repo it is not standing in.
- Every invocation appends one line to a local log: the command, the route
  given, and an optional free-text `-Area` tag. Deviations are annotated by
  hand, distinguishing a choice within the route from a floor breach.
- The map covers every pipeline command in its first pass. A partial map fails
  when it is most needed, because an unfamiliar command is exactly when it gets
  consulted.

Also in scope: a timeboxed spike on Junie (Rider) and Gemini, both already paid
for and unused. It establishes whether each has a scriptable entry point, what
its allowance actually permits, and where it sits in a chain relative to the
floor. A tool reachable only through an IDE tab can be useful by hand but cannot
be routed to, and that finding is a valid outcome. Two evening sessions, with
"what we know so far" acceptable at the end.

The PowerShell implementation is disposable. The route map is not: it is the
artifact this work exists to produce, and it ports to #26 as data if the .NET
orchestrator is built.

## Constraints

- Do not execute agents, launch processes, or mutate configuration. The advisor
  prints and appends to its log.
- Do not add anything to the packaged tree. Nothing here ships to consumers via
  `install.ps1`.
- Do not change the shipped `agents.tiers` defaults. `balanced` and `deep` stay
  `inherit`; repos opt in by pinning locally.
- Do not extend the `claude`/`cursor`/`codex` host set in `_harness-config.ps1`
  or `install.ps1`. That is a consumer-facing schema change.
- Do not write model ids into the route map.
- Do not track, estimate, or ask for quota state.
- Do not add a risk axis, a runtime task classifier, or unattended execution.
- Keep the build within evening sessions; it must not draw on time owed to the
  LamuFlix hiring-critical path.

## Acceptance checks

- Asking for a known command prints its full chain, best first, with the floor
  identified.
- Each option resolves to a concrete model where the target repo pins that tier,
  and to an explicit unpinned where it does not.
- `-RepoRoot` pointed at a second repo resolves that repo's pins, not the
  current checkout's.
- An unknown command is reported as absent from the map, not answered by
  default.
- Every row in the map carries a non-empty `why`.
- Every pipeline command in the `/pipeline` stage table has a row.
- Each invocation appends exactly one log line, carrying the `-Area` tag when
  given and omitting it when not.
- A floor breach is recordable in the log as distinct from a deviation within
  the route.
- A host with no `agents.tiers` entry yields host-level advice with no model,
  rather than an error.
- The advisor runs from a checkout with no `harness.yml` without failing.
- The packaged tree is unchanged; `install.ps1` output is byte-identical.
- The spike concludes with a written finding per tool: scriptable entry point
  yes or no, allowance, and placement relative to the floor.

## Not in scope

- Executing, launching, or orchestrating any agent.
- Quota ledgers, usage estimates, resumable runs, or unattended operation.
- A risk axis or deterministic risk scoring.
- A capability map: which model is stronger for frontend work, and which clears
  a given quality bar. The `-Area` tag exists to gather priors for it.
- The verdict on whether to build #26. The log is the evidence; the judgment is
  separate work.
