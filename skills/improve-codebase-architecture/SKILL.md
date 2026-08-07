---
name: improve-codebase-architecture
description: Scan a .NET codebase for deepening opportunities, present them as a visual HTML report, then grill through whichever one you pick.
disable-model-invocation: true
---

# Improve Codebase Architecture (.NET)

Surface architectural friction and propose **deepening opportunities** — refactors that turn shallow modules into deep ones. The aim is testability and AI-navigability.

This command is _informed_ by the project's domain model and built on a shared design vocabulary:

- Run the `/codebase-design` skill for the architecture vocabulary (**module**, **interface**, **depth**, **seam**, **adapter**, **leverage**, **locality**) and its principles (the deletion test, "the interface is the test surface", "one adapter = hypothetical seam, two = real"). Use these terms exactly in every suggestion — don't drift into "component," "service," "API," or "boundary."
- The domain language in `CONTEXT.md` gives names to good seams; ADRs in `docs/adr/` record decisions this command should not re-litigate.

## Process

### 1. Explore

**Scope before you scan — YAGNI.** Deepening a module pays off by making future changes to it easier, so put extra weight on the parts of the codebase that have recently changed. Decide *where* to look before you look:

- If the user named a direction — a project, a subsystem, a pain point — take it, and skip the inference below.
- Otherwise, walk back a good stretch of the commit history (`git log --oneline --stat`) to find the codebase's hot spots — the files and areas that keep coming up — and let those paths pull your attention first. If the changes are scattered with no clear hot spot, widen the net.

**Feed in metric evidence when available.** These are input signals, not verdicts — the deletion test and friction reading below still decide:

- **Stryker.NET survivors.** If `StrykerOutput/` reports exist (or the user can run `dotnet stryker`), clusters of surviving mutants mark code whose tests can't see it through its current interface — prime deepening territory.
- **Roslyn / NDepend complexity.** If the repo enforces cyclomatic complexity (CA1502 / NDepend rules), the files that keep tripping or hovering near the threshold are candidates.
- **Coverage gaps** from `dotnet test --collect:"XPlat Code Coverage"` — untested code that *can't* be tested through its interface is different from untested code nobody bothered with; only the former is architectural.

Read the project's domain glossary (`CONTEXT.md`) and any ADRs in the area you're touching first.

Then walk the codebase. Delegate this to a **read-only agent** when the host
provides one. Cursor and Claude Code can use the harness's `code-reviewer`
profile; Codex can spawn a general read-only subagent with the same brief.
Otherwise explore inline. Either way, don't follow rigid heuristics — explore
organically and note where you experience friction. The .NET-flavoured versions
of the usual suspects:

- Where does understanding one concept require bouncing between many small classes — the `IFooService` / `FooService` / `FooRepository` / `FooDto` / `FooMapper` parade for what is conceptually one operation?
- Where are modules **shallow** — interfaces with one implementation and no test double, repositories that wrap the data-access driver one-to-one adding nothing, handlers that only forward to a service?
- Where have pure static methods been extracted just for testability, but the real bugs hide in how they're called (no **locality**) — e.g. validation helpers tested in isolation while the GraphQL mutation that orchestrates them is untested?
- Where do tightly-coupled modules leak across their seams — persistence attributes (BSON, EF) on domain types, API layer types reaching directly into persistence records, `DateTime.UtcNow` and `new Random()` scattered where `TimeProvider` and an injected seeded `Random` should be?
- Which parts of the codebase are untested, or hard to test through their current interface — anything requiring a mocked data-access chain instead of a Testcontainers-backed seam?

Apply the **deletion test** to anything you suspect is shallow: would deleting it concentrate complexity, or just move it? A "yes, concentrates" is the signal you want.

### 2. Present candidates as an HTML report

Write a self-contained HTML file to the OS temp directory so nothing lands in the repo. Resolve the temp dir from `$TMPDIR`, falling back to `/tmp` (or `%TEMP%` on Windows), and write to `<tmpdir>/architecture-review-<timestamp>.html` so each run gets a fresh file. Open it for the user — `open <path>` on macOS, `xdg-open <path>` on Linux, `start <path>` on Windows — and tell them the absolute path.

The report uses **Tailwind via CDN** for layout and styling, and **Mermaid via CDN** for diagrams where a graph/flow/sequence reliably communicates the structure. Mix Mermaid with hand-crafted CSS/SVG visuals — use Mermaid when relationships are graph-shaped (call graphs, dependencies, sequences), and hand-built divs/SVG when you want something more editorial (mass diagrams, cross-sections, collapse animations). Each candidate gets a **before/after visualisation**. Be visual.

For each candidate, render a card with:

- **Files** — which projects/files/modules are involved
- **Problem** — why the current architecture is causing friction
- **Solution** — plain English description of what would change
- **Benefits** — explained in terms of locality and leverage, and how tests would improve (name the seam the new tests would cross, and whether Stryker survivors in the area would die)
- **Before / After diagram** — side-by-side, custom-drawn, illustrating the shallowness and the deepening
- **Recommendation strength** — one of `Strong`, `Worth exploring`, `Speculative`, rendered as a badge

End the report with a **Top recommendation** section: which candidate you'd tackle first and why.

**Use CONTEXT.md vocabulary for the domain, and the `/codebase-design` vocabulary for the architecture.** If `CONTEXT.md` defines "Order," talk about "the Order intake module" — not "the OrderCommandHandlerService," and not "the Order service."

**ADR conflicts**: if a candidate contradicts an existing ADR, only surface it when the friction is real enough to warrant revisiting the ADR. Mark it clearly in the card (e.g. a warning callout: _"contradicts ADR-0007 — but worth reopening because…"_). Don't list every theoretical refactor an ADR forbids.

See [HTML-REPORT.md](HTML-REPORT.md) for the full HTML scaffold, diagram patterns, and styling guidance.

Do NOT propose interfaces yet. After the file is written, ask the user: "Which of these would you like to explore?"

### 3. Grilling loop

Once the user picks a candidate, run the `/grilling` skill to walk the decision tree with them — constraints, dependencies, the shape of the deepened module, what sits behind the seam, what tests survive.

Side effects happen inline as decisions crystallize — run the `/domain-modeling` skill to keep the domain model current as you go:

- **Naming a deepened module after a concept not in `CONTEXT.md`?** Add the term to `CONTEXT.md`. Create the file lazily if it doesn't exist.
- **Sharpening a fuzzy term during the conversation?** Update `CONTEXT.md` right there.
- **User rejects the candidate with a load-bearing reason?** Offer an ADR, framed as: _"Want me to record this as an ADR so future architecture reviews don't re-suggest it?"_ Only offer when the reason would actually be needed by a future explorer to avoid re-suggesting the same thing — skip ephemeral reasons ("not worth it right now") and self-evident ones.
- **Want to explore alternative interfaces for the deepened module?** Run the `/codebase-design` skill and use its design-it-twice parallel sub-agent pattern.
