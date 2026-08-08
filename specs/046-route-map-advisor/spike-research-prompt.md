# Spike research prompt: Junie and Gemini CLI capability

Delegation prompt for the fact-finding half of the #46 spike. Paste into a
cheap host (Cursor's included models are sufficient — the binding requirement
is web access, not reasoning depth).

**What this covers and what it does not.** The spike has two halves. This
prompt covers only the research: what each tool can do and what the existing
licence grants. Placing each tool in a route chain relative to the floor is a
judgment call that stays with a human, because it writes content into the
durable route map. See `brief.md` and `docs/adr/0008-route-map-records-work-demands.md`.

**Reading the results.** A tool with no scriptable entry point does not belong
in `route-map.json` at all — it can still be used by hand, but nothing can be
routed to it. A tool with a generous included allowance likely sits below the
Claude and Cursor entries but above the floor: already-paid capacity is worth
reaching for before quality is compromised, but not before the best option.

---

```text
# Research task: Junie and Gemini CLI capability

You are doing FACT-FINDING ONLY. Do not make recommendations, and do not
decide how these tools should be used. Report what you can verify.

Today's date is 8 August 2026. Flag any source older than ~12 months as
possibly stale.

## Why this matters

We are deciding whether two already-paid-for AI coding tools can be driven
by a script. A tool that can only be used by clicking inside an IDE window
can still be useful to a human, but it cannot be automated. That single
distinction is what this research decides, so be precise about it.

## Questions

### A. Junie (JetBrains)

A1. Does Junie have a command-line interface or any headless / scriptable
    entry point? Specifically: can it be invoked from a terminal or script
    with a prompt, without a human clicking in the IDE?
A2. If yes: what is the exact command, and what flags does it accept for
    passing a prompt non-interactively?
A3. What does a paid JetBrains license (Rider, or the All Products Pack)
    include for Junie? Look for: quota, credits, usage limits, and whether
    Junie is included at all or costs extra.
A4. Which underlying models does Junie run on? Can the user choose the
    model, or is it fixed?
A5. Is there any documented API or programmatic access?

### B. Gemini

B1. Is there an official Google Gemini command-line tool? If so, what is
    it called and where does it live?
B2. Can it be invoked non-interactively with a prompt from a script?
    Give the exact flag or syntax.
B3. How does it authenticate? Specifically distinguish: signing in with a
    personal Google account, versus supplying an API key. These may have
    different limits.
B4. What usage does a consumer Google AI subscription (Google One AI
    Premium / Gemini Advanced, sometimes marketed as "Plus") grant for
    that CLI — as opposed to a separate paid API key?
B5. What are the documented rate limits or daily request quotas for each
    authentication path?
B6. Which models are reachable through it?

## Rules

RULE 1 — Cite every claim.
Every single answer must include a URL. If you cannot produce a URL for a
claim, do not make the claim.

RULE 2 — Never confuse "does not exist" with "I could not find it."
These are different findings and must be labelled differently:
  - CONFIRMED     = a source states this directly.
  - NOT FOUND     = you searched and found nothing either way. This does
                    NOT mean the feature is absent.
  - CONTRADICTORY = sources disagree. Cite both.
Do not write "Junie has no CLI" unless a source says so. If you searched
and found nothing, the answer is NOT FOUND.

RULE 3 — Do not install anything, run any installer, or execute any
downloaded file. This is desk research only.

RULE 4 — Prefer official documentation (jetbrains.com, google.dev,
ai.google.dev, official GitHub repos) over blog posts and forum threads.
If you must use a secondary source, say so.

## Output format

One markdown table, exactly these columns:

| ID | Question | Finding | Status | Source URL | Notes |

- ID is A1, A2, B1, ... matching above.
- Status is one of: CONFIRMED / NOT FOUND / CONTRADICTORY.
- Notes is for caveats, dates, and version numbers.

After the table, add a short section titled "Open questions" listing
anything you could not resolve and what would resolve it.

Do not add a summary, a recommendation, or a conclusion.
```

---

## Why the prompt is shaped this way

**The "why this matters" section is not padding.** A model that understands the
CLI-versus-IDE distinction is the entire decision will research it harder than
one working through a checklist.

**Rule 2 is the load-bearing guardrail.** The failure mode that costs the most
is a false negative — "Junie has no CLI" when it does — because it would drop
already-paid capacity from the route map permanently and nobody would revisit
it. The repository already separates *Failure* from *Could not run* in
`CONTEXT.md` for the same reason: a verdict reached without evidence is not a
verdict. Requiring a URL per claim turns a silent miss into a ten-second check.

**Rule 3 exists because this is delegated to a cheap model with web access.**
Desk research has no reason to execute anything.
