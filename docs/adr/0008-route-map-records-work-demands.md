# Route map records work demands, not model capabilities

Subscription quota is the binding constraint, and it runs out mid-week with work
still to do. Deciding what to run where needs two different kinds of knowledge:
what a piece of work demands, and what a given model provides. Issue #46 asked
for a "static capability map from public model knowledge", which names the
second. The artifact that actually answers the question is the first, and the
two rot at different rates — "`/speckit-plan` needs deep reasoning" holds for
years, while "deep on Claude means this model id" churns every few months.

Conflating them puts a volatile fact inside a stable judgment, so every model
rename invalidates a table of reasoning that did not change.

## Decision

### The map describes work

The route map is keyed by pipeline command and records what that command
demands: an ordered chain of host and tier options, best first, with a floor
marking the lowest option that still does the work without losing quality. Each
row carries a `why`. The rationale is the durable part — a conclusion without it
cannot be revised when evidence contradicts it, only replaced by a fresh guess.

The map never names a model.

### Model identity comes from `agents.tiers`

A tier resolves to a concrete model through `agents.tiers` in the target repo's
`harness.yml`, read with the existing loader. That table is already the single
place model ids live and is already consumed by `install.ps1` when it renders
agent discovery copies. A model rename stays a one-line fix there.

Where a tier names no model — `balanced` and `deep` ship as `inherit` — the
route resolves to an explicit unpinned rather than to a guess. A repo that wants
concrete advice pins those tiers in its own `harness.yml`.

### Quota state comes from the human

Nothing tracks or estimates remaining quota. The advisor prints the whole chain
and the floor; the human reads down to the first option they still have
allowance for. If that lands below the floor, the work waits.

## Rejected alternatives

**Name models in the map directly.** Self-contained and needs no config
reading. But it puts model ids in a second place, so a rename means editing both
files, and it is the failure the existing `harness.yml` comment was written to
prevent. It also destroys the property that makes the map durable: judgments
about work would become entangled with facts that expire.

**Track quota in a local ledger.** The advisor could then pick for you rather
than printing a chain. There is no machine-readable quota API, so the ledger
would be hand-fed and stale within a day — and a confidently wrong "you have
room" is worse than no answer. The human already holds this fact for free.

**Add a risk axis now.** `role x risk x phase` is the eventual model, and
`/implement` genuinely wants it. But risk multiplies the cells authored from the
same unbenchmarked priors, and a bad outcome could then not be attributed to the
command judgment or the risk judgment. The map is an experiment before it is a
tool; attributable results matter more than coverage.

## Accepted cost

Out of the box the advisor is concrete about `fast` work and silent about
`deep` work, because only `fast` ships pinned. That is the inverse of where the
tokens are. Useful advice on `/implement` requires a one-time local pin, and a
repo that never does it gets an advisor that shrugs at its most expensive
command. Changing the shipped defaults instead was rejected: `fast` is pinned
because its work is mechanically checkable, and pinning `deep` for every
consumer would override that quality argument to serve one repo's convenience.

The advisor recommends and does not enforce. Advice that must be remembered will
sometimes not be, so the map cannot be relied on to have been followed. This is
accepted because the map is being tested, not deployed: the occasions it was
ignored are findings, and are recorded as deviations rather than suppressed.

## Consequences

The host axis is open in the route map and closed in `agents.tiers`.
`install.ps1` validates hosts against `claude`, `cursor`, and `codex`, so a host
outside that set — `antigravity`, `junie` — can appear in a route and receive
host-level advice, but has no tier to resolve and therefore no model. Extending
the closed set is a packaged, consumer-facing schema change and is deliberately
not part of this work. It is tracked in #76, where the metered-versus-flat-rate
distinction those hosts introduce is the open schema question.

That openness turned out to be load-bearing rather than theoretical. The spike
routed two hosts the closed set could not have expressed, and one of them —
`antigravity` — did not exist under that name when this decision was taken: it
replaced the standalone Gemini CLI, which was deprecated mid-flight. A closed
host axis would have required a packaged schema change to record a fact that
changed within a week.

Issue #26's note that `agents.tiers` is "schema-validated but not consumed" is
stale. `install.ps1` consumes it today to stamp `model` and `effort` into
generated agent frontmatter, which means routing by role already ships and only
risk and phase remain unbuilt.
