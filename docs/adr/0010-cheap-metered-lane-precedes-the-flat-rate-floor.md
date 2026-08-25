# A cheap metered lane precedes the flat-rate floor

The route map orders hosts by billing, not by quality: flat-rate subscription
capacity is spent first because it is already paid for whether used or not, and
metered capacity is held back as reserve. `antigravity` and `junie` sit between
the primaries and the floor on that rule, and the rule has held since the map
was authored.

Issue #101 asks for a cheap OpenRouter lane for low-judgment coding work. Every
placement that obeys the billing rule makes that lane unreachable. On the
mechanical commands the whole chain is one tier — `/task` is `cursor:fast`,
`gemini-api:fast`, then a `claude:fast` floor — so there is no tier drop for a
reserve to prevent. A metered row placed by the billing rule would sit below a
flat-rate row of the same tier, and the reader, told to take the first option
they still have allowance for, would never reach it.

## Decision

`openrouter:fast` is placed **above** the flat-rate floor on the four mechanical
commands: `/task`, `/speckit-specify`, `/speckit-tasks`, `/gherkin`. It stays
below the free `gemini-api` lane.

This is the one place in the map where metered capacity is spent ahead of
flat-rate, and the reason is price, not quality. `Invoke-OpenRouterTask.ps1`
resolves `fast` to `deepseek/deepseek-v4-flash` at $0.077 / $0.154 per 1M tokens
(verified against OpenRouter on 2026-08-25). A mechanical run costs cents. The
flat-rate floor draws on the same weekly Claude and Cursor allowance that
`/implement` and `/speckit-plan` compete for, and that allowance is the binding
constraint ADR 0008 was written around — it runs out mid-week with work still to
do.

So the trade is cents against the scarcest resource in the pipeline. Spending
the cheap metered pool to keep judgment capacity for the stages that need it is
the whole point of the lane.

The billing rule is not repealed. It still governs `antigravity` and `junie`,
whose consumption is proportional to token cost at frontier prices. The
exception is narrow and stated where it applies: a metered lane may precede
flat-rate when its marginal cost is negligible **and** the flat-rate capacity it
displaces is contended by higher-judgment work.

### The lane stays off the reasoning-heavy commands

`/architect`, `/grill-with-docs`, `/implement`, `/speckit-analyze`,
`/speckit-plan`, and `/refactor` keep no OpenRouter row, for the same reason
`gemini-api` has none: those are the rows where a shallow model's miss is
silent, and price is not an argument against that. `Test-RouteMap.ps1` asserts
their absence, and that assertion is left in force rather than relaxed.

## Rejected alternatives

**Place the cheap lane below the floor.** Honest about quality ordering and
needs no exception to the billing rule. But the floor means "the lowest option
that still does the work"; anything below it is by definition not worth running,
and the map has no way to say "cheaper and still fine". It would encode the
lane as substandard when the claim being made is the opposite.

**Move the floor down to the OpenRouter row.** Makes the lane reachable without
an exception. Rejected because the floor is a quality statement about
unbenchmarked models — `deepseek-v4-flash` has no evidence behind it here beyond
its price and its claimed coding fit. Declaring it the quality floor for four
commands asserts far more than is known.

**Route the free `stealth/ox-alpha` preview instead.** It is $0.00 per 1M at
1.05M context, which would remove the trade entirely. Rejected on two grounds:
it is an anonymous preview endpoint whose provider sees the prompts, which
disqualifies it for anything non-public, and a preview slug disappears without
notice — a routed row that vanishes is worse than one that costs cents.

## Accepted cost

The map now has two orderings in it, and a reader who learned the billing rule
from the `notes` will find a row that contradicts it. That is mitigated by
stating the exception in the same `notes` and by this ADR, but it is a real cost:
the map's one-rule simplicity is gone, and a future host will have to be argued
against two rules instead of one.

The saving is also unmeasured. Nothing tracks what the mechanical commands
actually consume, so the claim that this preserves meaningful judgment capacity
is a prior, not a finding. Route deviations recorded through
`Add-RouteDeviation.ps1` are the evidence that will confirm or refute it, and
this row should be revisited once there are enough of them to read.

## Consequences

`openrouter` appears on six commands rather than two, and on two different
tiers: `deep` for `/code-review`, `balanced` for `/ship-review`, and `fast` for
the four mechanical rows. Those tiers now resolve to three different models
through the launcher's tier table rather than to `z-ai/glm-5.2` throughout, so
the tier on an OpenRouter row became a spend decision as well as an effort one.

`agents.tiers` still cannot express any of this — `openrouter` remains outside
the closed host set, so every row resolves unpinned and the launcher's table is
the only place the tier-to-model mapping exists. That split is the same open
schema question tracked in #76, now with a second consumer.
