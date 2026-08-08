# Research: Junie and Gemini CLI capability

Fact-finding only. Research date: **8 August 2026**.  
Sources older than ~12 months are flagged in Notes as possibly stale.

## Findings

| ID | Question | Finding | Status | Source URL | Notes |
| --- | --- | --- | --- | --- | --- |
| A1 | Does Junie have a CLI / headless / scriptable entry point usable without clicking in an IDE? | Official docs describe **Junie CLI** as a terminal agent and a **Non-interactive (headless) mode** for CI/CD and build pipelines, with installers for Linux/macOS/Windows and invocation as `junie`. | CONFIRMED | https://junie.jetbrains.com/docs/junie-cli.html ; https://junie.jetbrains.com/docs/junie-headless.html | Docs page dated **05 August 2026**. Blog announcement of Junie CLI Beta: https://blog.jetbrains.com/junie/2026/03/junie-cli-the-llm-agnostic-coding-agent-is-now-in-beta/ (March 2026). |
| A2 | Exact command and flags for non-interactive prompt | Headless usage documented as: `junie --auth="$JUNIE_API_KEY" "<prompt as positional argument>"`. Alternatives: `--task "..."` or env `JUNIE_TASK`. Auth via `-a`/`--auth` or `JUNIE_API_KEY`. Model via `--model` / `JUNIE_MODEL`. Project via `-p`/`--project`. Review: `--review`. Full flag list in CLI reference. **Note:** `--prompt` / `JUNIE_PROMPT` starts **interactive** TUI with an auto-submitted first prompt (session stays interactive)—not the headless path. | CONFIRMED | https://junie.jetbrains.com/docs/junie-headless.html ; https://junie.jetbrains.com/docs/parameters.html ; https://junie.jetbrains.com/docs/environment-variables.html | Official CLI reference does **not** list a `--headless` flag; headless is the non-interactive task/`--auth` path. Secondary sites that claim `--headless` were not used as authorities. |
| A3 | What a paid JetBrains license (Rider / All Products Pack) includes for Junie (quota, credits, extra cost) | **Junie is included** in JetBrains AI plans (AI Free / AI Pro / AI Ultimate list Junie). **Paid All Products Pack and paid dotUltimate include AI Pro** (not free/student/OSS APP). Product pricing page: **AI Pro** = 10 AI Credits / 30 days (top-ups allowed); **AI Ultimate** = 35 AI Credits / 30 days (recommended for regular Junie). Licensing help also lists credit tables (Pro 10 or 20; Ultimate 35 or 70 depending on table) and org pool contribution **APP/dotUltimate = 20 credits/month**. **Standalone Rider alone including AI Pro:** not stated on the APP/dotUltimate FAQ; Junie product page lists Rider among supported IDEs. | CONFIRMED (bundling/credits on cited pages); NOT FOUND (standalone Rider ⇒ AI Pro) | https://www.jetbrains.com/junie/ ; https://www.jetbrains.com/help/ai-assistant/licensing-and-subscriptions.html ; https://sales.jetbrains.com/hc/en-gb/articles/16544922728466-Is-JetBrains-AI-subscription-included-in-All-Products-Pack-or-dotUltimate ; https://www.jetbrains.com/help/ai/ai-service-license.html | Help page last note **22 July 2026**. Older AI service license page last modified **18 June 2025** (possibly stale vs credit numbers). Credit figures differ across JetBrains pages (10/35 vs 20/70)—treat as **CONTRADICTORY** on exact credit count. BYOK / usage-based `JUNIE_API_KEY` also documented separately: https://junie.jetbrains.com/docs/junie-cli.html |
| A4 | Underlying models; user-selectable? | User can choose model: `/model`, `--model`, `JUNIE_MODEL`. Default is a dynamic “best price-quality” model. Documented aliases (as of page date): `sonnet`→Claude Sonnet 4.6; `opus`→Claude Opus 4.8; `gpt`→GPT-5.4; `gpt-codex`→GPT-5.3-codex; `gemini-pro`→Gemini 3.1 Pro Preview; `gemini-flash`→Gemini 3 Flash; `grok`→Grok 4.3. Providers: JetBrains AI subscription, BYOK (OpenAI/Anthropic/Google/xAI/OpenRouter), custom profiles, proxy. Available set depends on auth method. | CONFIRMED | https://junie.jetbrains.com/docs/junie-cli-model-selection.html ; https://junie.jetbrains.com/docs/junie-cli.html | Page dated **05 August 2026**. Alias→concrete model mapping “may change as new models are released.” |
| A5 | Documented API / programmatic access | Documented programmatic surfaces: **CLI headless mode**, **env-var driven CI config**, **`--acp` (Agent Client Protocol)** for IDE/editor integrations, plus GitHub/GitLab CI docs linked from env-vars page. **Separate public REST/HTTP “Junie API” for driving the agent:** not found in official docs searched. | CONFIRMED (CLI/ACP/CI); NOT FOUND (REST HTTP agent API) | https://junie.jetbrains.com/docs/junie-headless.html ; https://junie.jetbrains.com/docs/parameters.html ; https://junie.jetbrains.com/docs/environment-variables.html | `JUNIE_API_KEY` is an auth token for Junie CLI (generate at https://junie.jetbrains.com/cli), not evidence of a general REST agent API in the docs reviewed. |
| B1 | Official Google Gemini CLI? Name and home? | Yes. Official open-source **Gemini CLI**; docs site and GitHub `google-gemini/gemini-cli`; install via `npm install -g @google/gemini-cli`, Homebrew `brew install gemini-cli`, or `npx https://github.com/google-gemini/gemini-cli`. Binary invoked as `gemini`. | CONFIRMED | https://google-gemini.github.io/gemini-cli/ ; https://github.com/google-gemini/gemini-cli | Also referenced from Google for Developers: https://developers.google.com/gemini-code-assist/docs/gemini-cli |
| B2 | Non-interactive invoke with a prompt from a script? | Yes. Headless/non-interactive: `gemini --prompt "..."` or `gemini -p "..."`; also stdin pipe (`echo "..." \| gemini`). Docs state this is for scripting/automation/CI. | CONFIRMED | https://google-gemini.github.io/gemini-cli/docs/cli/headless.html ; https://google-gemini.github.io/gemini-cli/ | Related flags in same headless doc: `--output-format`, `-m`/`--model`, `-y`/`--yolo`, `--approval-mode`. |
| B3 | Authentication: Google account vs API key | Interactive options: (1) **Login with Google** (OAuth; docs say use this for Google AI Pro/Ultra subscribers); (2) **Gemini API key** via `GEMINI_API_KEY` from Google AI Studio; (3) **Vertex AI** (ADC / service account / `GOOGLE_API_KEY` + `GOOGLE_GENAI_USE_VERTEXAI=true`). Headless without cached login requires env vars (`GEMINI_API_KEY` or Vertex setup)—CLI errors if none found. | CONFIRMED | https://google-gemini.github.io/gemini-cli/docs/get-started/authentication.html | Auth method affects quotas/ToS (same page points to quotas doc). |
| B4 | What Google One AI Premium / Gemini Advanced / Google AI Pro grants for the CLI vs paid API key | **Gemini CLI quota page:** Google AI Pro / AI Ultra described as fixed-price upgrade path via Login with Google; **Gemini for Workspace / consumer web Gemini plans “do not apply” to API usage that powers Gemini CLI**. **Google Developers deprecation (effective 18 June 2026):** Gemini Code Assist for individuals, **Google AI Pro, and Google AI Ultra stopped serving** for IDE extensions **and Gemini CLI**; **Login with Google no longer usable** for those consumer tiers; migrate to **Antigravity**; Standard/Enterprise Code Assist unchanged. | CONTRADICTORY | https://google-gemini.github.io/gemini-cli/docs/quota-and-pricing.html ; https://google-gemini.github.io/gemini-cli/docs/get-started/authentication.html ; https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals | Deprecation is dated **June 18, 2026** (current as of research date 8 Aug 2026). Gemini CLI auth/quota pages still describe Google AI Pro/Ultra + Login with Google—stale relative to deprecation, or not yet updated. Exact “Google One AI Premium” / “Gemini Advanced” naming is not used on the CLI quota page; closest official names are Google AI Pro/Ultra and Workspace/web Gemini plans. |
| B5 | Documented rate limits / daily quotas per auth path | **Gemini CLI quotas page:** Login with Google (Code Assist for individuals): **1000 req/user/day**, **60/min**. Unpaid Gemini API key: **250/day**, **10/min**, **Flash only**. Code Assist Standard: **1500/day**, **120/min**. Enterprise: **2000/day**, **120/min**. API key / Vertex pay-as-you-go: limits vary by tier (links to Gemini API / Vertex docs). **Homepage also states** Login free tier **60/min and 1000/day**, but API-key free tier **100 requests/day with Gemini 2.5 Pro**—disagrees with quotas page’s 250/day Flash-only. **Deprecation** removes consumer Login-with-Google path as of 18 Jun 2026. Cloud Code Assist agent+CLI combined daily caps for Standard/Enterprise also at https://cloud.google.com/gemini/docs/quotas (1500/2000). | CONTRADICTORY (homepage vs quotas page for API-key free tier; quotas page vs deprecation for consumer Google login) | https://google-gemini.github.io/gemini-cli/docs/quota-and-pricing.html ; https://google-gemini.github.io/gemini-cli/ ; https://cloud.google.com/gemini/docs/quotas ; https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals | Gemini API rate-limits page fetch timed out in this session; quotas page links to https://ai.google.dev/gemini-api/docs/rate-limits for paid API-key detail. |
| B6 | Which models are reachable through Gemini CLI? | Docs state access to **Gemini** models; homepage highlights **Gemini 2.5 Pro** (1M context) and example `-m gemini-2.5-flash`. Headless JSON example references `gemini-2.5-pro` and `gemini-2.5-flash`. Login-with-Google path: “across the Gemini model family as determined by Gemini CLI.” Model selectable with `-m` / `--model`. | CONFIRMED | https://google-gemini.github.io/gemini-cli/ ; https://google-gemini.github.io/gemini-cli/docs/cli/headless.html ; https://google-gemini.github.io/gemini-cli/docs/quota-and-pricing.html | Exact exhaustive model catalog for every auth path was **NOT FOUND** as a single fixed list on the pages reviewed; selection is CLI-determined and/or `-m`. |

## Open questions

1. **Exact AI Credit entitlement for a standalone Rider license (not APP/dotUltimate)** — official FAQ confirms APP/dotUltimate → AI Pro; no cited page states Rider-alone → AI Pro. Resolve via JetBrains Account license view or JetBrains sales FAQ for Rider specifically.
2. **Which of JetBrains’ published credit tables (10/35 vs 20/70) applies to a given individual annual vs monthly purchase** — pages disagree. Resolve by checking the live JetBrains AI widget / account for the specific SKU.
3. **Whether Login with Google still works at all for Gemini CLI after 18 June 2026 for free Google accounts** — deprecation text focuses on Code Assist individuals / Google AI Pro / Ultra; Gemini CLI homepage/quota docs still advertise free Login quotas. Resolve by re-reading an updated Gemini CLI auth/quotas page or Google I/O announcement linked from the deprecation page.
4. **What quota a former “Google One AI Premium / Gemini Advanced” subscriber actually has for Gemini CLI today** — official CLI docs say Workspace/web Gemini plans do not apply to CLI; deprecation points consumer subscribers to Antigravity pricing (URL referenced but not fully retrieved here). Resolve at the Antigravity pricing page linked from https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals .
5. **Paid Gemini API key free-tier numbers** — homepage (100/day, 2.5 Pro) vs quotas page (250/day, Flash only). Resolve via https://ai.google.dev/gemini-api/docs/rate-limits (fetch timed out here).
6. **Whether JetBrains publishes a REST HTTP API to drive Junie without the `junie` binary** — CLI/ACP/CI documented; REST agent API not found. Resolve by searching junie.jetbrains.com docs for “API” beyond `JUNIE_API_KEY`, or asking JetBrains support.

---

## Resolved by direct observation (8 August 2026)

Verified from the installed Rider environment, not from documentation.

### Entitlement — open question 1 is CLOSED

The licence is **All Products Pack**. The cited JetBrains FAQ confirms APP includes
AI Pro, so **Junie is entitled**. Junie CLI `v.26.8.3` runs locally and connects to
the IDE.

### Junie exposes model *and* effort — this matters for the route map

The running CLI's status bar reads `Gemini 3 Flash Preview  JetBrains AI` and
`High effort`. Two consequences:

- Junie's controls are exactly the `{model, effort}` pair `agents.tiers` already
  models per host. Junie is shaped like a first-class host, not like a fixed tool.
- Junie was observed billing through **JetBrains AI**, not through the user's own
  Google account. Its credits are a pool **separate from** Claude Pro, Cursor, and
  Codex — which is the entire reason it is worth routing to.

### Rider is a multi-agent ACP host — not anticipated by the spike

`Settings > Tools > AI Assistant > Agents` lists installed ACP adapters: Claude
Agent (bundled), Codex (bundled), Cursor, Devin, Gemini CLI, GitHub Copilot,
Grok Build, Junie (bundled), Kimi CLI, with an ACP registry for more.

**This does not create capacity.** Running Claude Agent inside Rider still draws
Anthropic quota; Cursor still draws Cursor quota. The front-end changed, the pool
did not. Only **Junie** draws JetBrains AI credits. Treating the agent list as new
headroom would be the error to avoid here.

### Gemini — no route rows, deliberately

The subscription is **Google AI Plus**, and the usage page showed 0% of both the
daily and weekly limits consumed.

That meter is the **consumer Gemini app**, which the cited quota page states does
**not** apply to the API usage powering Gemini CLI. An unused web-app allowance is
not evidence of CLI entitlement. The 18 June 2026 deprecation names Google AI Pro
and Ultra; **Plus is not mentioned either way**, so its status is genuinely
unknown rather than confirmed working.

Gemini CLI `v0.54.4` being *installed* in Rider proves the adapter is present, not
that the licence authorises it.

Per Rule 2, `NOT FOUND` is not permission to act. **No Gemini rows enter the route
map until an actual `gemini -p` call is observed succeeding under this account.**
That is a one-command check and the cheapest way to close open questions 3 and 4.

#### Attempt 1 — inconclusive, environment fault

`gemini --version` failed on `SyntaxError: 'node:events' does not provide an
export named 'addAbortListener'` under **Node.js v18.16.0**. `addAbortListener`
was added in Node v20.5.0, so the CLI crashes at module load, before reaching
authentication.

This says nothing about entitlement.

#### Attempt 2 — CLOSED. The deprecation is real; Antigravity is the successor

**Antigravity CLI 1.1.11**, authenticated as **Google AI Plus**, answered both
probes:

- `Reply with exactly: ROUTE_TEST_OK` returned `ROUTE_TEST_OK`.
- After `/model` set **Gemini 3.1 Pro (Low)**, `Reply with exactly: PRO_OK`
  returned `PRO_OK` — so this is **not** a Flash-only tier.

Open questions 3 and 4 are closed. Standalone Gemini CLI stays out of the route
map permanently: it is deprecated, and `antigravity` is the entry that replaces it.

##### Two independent weekly pools — new to this map

`/credits` reports quota split into **two separate weekly limits**:

| Pool | Models | Observed remaining |
| --- | --- | --- |
| Gemini | Gemini Flash, Gemini Pro | 97.40% (refreshes in ~168h) |
| Claude and GPT | Claude Opus, Claude Sonnet, GPT-OSS | 100.00% |

The tool states quota is *"consumed proportionally to the cost of the tokens,"*
so limits stretch with cheaper models — the same metered behaviour as Junie,
expressed as a weekly percentage rather than credits.

The consequence for routing is specific to this host: **choosing a tier also
chooses which pool drains.** An exhausted Claude pool does not block Gemini-model
work, and vice versa. No other host in the map has this property.

It also resolves the earlier confusion about the consumer usage meter. That meter
tracks the Gemini web app; `/credits` is the pool that actually backs CLI work,
and the two are independent.

### Correction: headless capability was the wrong inclusion criterion

The research prompt asserted that a tool usable only through an interactive
window *"cannot be automated. That single distinction is what this research
decides."* Applied to route-map inclusion, that was wrong.

The MVP is an **advisor**, not a dispatcher — it prints a recommendation for a
human, and never launches a process. A human can use an interactive TUI perfectly
well, so **interactive-only tools are routable for #46**.

Headless capability decides eligibility for **#26**, the orchestrator that
actually launches processes. It is recorded here for that reason, but it does not
gate a row in `route-map.json`.

Antigravity is therefore routed on the strength of working, entitled, and largely
unused quota.

### Antigravity is fully orchestratable — the binary is `agy`

The command is **`agy`**, not `antigravity`
(`C:\Users\lamun\AppData\Local\agy\bin\agy.exe`). `agy --help` answers the #26
question decisively — and more completely than the epic assumed it would have to
build against.

| Capability | Flag | Matters to |
| --- | --- | --- |
| Non-interactive prompt | `-p` / `--print` / `--prompt` | #26 dispatch |
| **NDJSON output** | `--output-format stream-json` (also `text`, `json`) | #31/#32 adapters |
| Enforced structured output | `--json-schema <schema-or-path>` | typed envelopes |
| Session resume | `--conversation <ID>`, `--continue` / `-c` | #33 run store |
| Model + effort | `--model`, `--effort low\|medium\|high` | #76, `agents.tiers` |
| Execution mode | `--mode accept-edits\|plan` | writer vs reader nodes |
| Workspace scoping | `--add-dir` (repeatable) | #35 write scopes |
| Sandbox | `--sandbox` (terminal restrictions) | isolation |
| Capability probe | `agy models`, `agy agents` | #30 probes |
| Print-mode timeout | `--print-timeout` (default 5m) | per-node budgets |

`--output-format stream-json` is the NDJSON contract #26 specifies, and
`--effort low|medium|high` matches the harness's existing effort field exactly.
On this evidence `agy` may be the *cheapest* adapter in the epic to build, not
the hardest.

Two cautions for #35: **`--dangerously-skip-permissions`** auto-approves every
tool permission request and must stay off for any writer node, and
`--disable-slash-commands` exists because slash expansion is otherwise live in
print mode.

### Model inventory — corrects an earlier claim

`agy models` returns eleven entries, with effort baked into the id alongside the
separate `--effort` flag:

- **Gemini pool:** `gemini-3.6-flash-{high,medium,low}`,
  `gemini-3.5-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`
- **Claude/GPT pool:** `claude-sonnet-4-6`, `claude-opus-4-6-thinking`,
  `gpt-oss-120b-medium`

Earlier notes here said both reserve hosts "reach Claude Opus and Sonnet,"
implying parity with the `claude` host. That was too loose. Antigravity tops out
at **Opus 4.6 / Sonnet 4.6**, a generation behind Junie's **Opus 5 / Sonnet 5**,
and its GPT option is the open-weights `gpt-oss-120b`, not GPT-5.x.

That is why the two reserves are ordered antigravity-then-junie rather than by
raw capability: both clear the floor, so the plentiful weekly pool is spent
before the scarce 10-20 monthly credits, and junie is reached past antigravity
only when the work genuinely wants the newer generation.

### Junie runs the same top-tier models — corrects the routing rationale

Junie's model picker (`/model`) lists 22 models, all with provider **JetBrains AI**,
with per-model pricing and an effort control:

| Model | Input / Output (per Mtok) |
| --- | --- |
| Gemini 3.1 Flash Lite / 3.5 Flash Lite | $0.25 / $1.50 |
| GPT-5.6-LUNA | $0.20 / $1.20 |
| Gemini 3 Flash Preview *(default)* | $0.50 / $3.00 |
| Gemini 3.6 Flash | $0.75 / $3.75 |
| Gemini 3.1 Pro Preview, GPT-5.6-TERRA | $2.00 / $12.00 |
| Claude Sonnet 5 | $2.00 / $10.00 |
| Claude Sonnet 4.6 | $3.00 / $15.00 |
| **Claude Opus 5**, Opus 4.6/4.7/4.8 | $5.00 / $25.00 |
| GPT-5.5, GPT-5.6-SOL | $5.00 / $30.00 |
| Claude Fable 5 | $10.00 / $50.00 |
| Grok 4.3 | $1.25 / $2.50 |

Two corrections follow.

**Junie is not a quality step down.** It reaches Claude Opus 5 and Sonnet 5 —
the same models the `claude` host runs. Its position below `claude` and `cursor`
in every route is a **billing** decision, not a quality one: flat-rate capacity is
already paid for whether used or not, so it is spent first, and metered credits are
held in reserve. This is also what justifies Junie sitting *above* the floor —
reaching for equal-quality metered capacity beats dropping a tier.

**Cost is metered, so the tier matters more here than elsewhere.** On Claude Pro or
Cursor Pro, picking a stronger model costs nothing extra until the periodic limit
is hit. On Junie every token is priced, so `junie:deep` on Opus-class models drains
a 10-20 credit budget quickly while `junie:fast` on Flash Lite or GPT-5.6-LUNA
stretches it by roughly 20x on input.
