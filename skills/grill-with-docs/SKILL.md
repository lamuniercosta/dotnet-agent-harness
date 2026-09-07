---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADRs and glossary) as we go. Run before /speckit-specify so the spec is written from settled vocabulary.
disable-model-invocation: true
---

Run a `/grilling` session, using the `/domain-modeling` skill.

After each decision crystallizes and the user confirms it, write `specs/<feature>/CONCLUSIONS.md` **before** treating the resolved transcript as compactable. Ordering is mandatory, not implied:

1. **Write first.** Append the full decision exchange to `specs/<feature>/CONCLUSIONS.md` alongside `brief.md`: every question and answer that led to the decision, the user's decision, the rationale, and the implications. Do not record only the crystallizing question and answer.
2. **Then declare safe.** Once that write exists, the resolved Q&A is safe for the host's context-management system to summarize away. Artifact existence is the compaction license. This is a declaration to the host, not an active command — do not invoke a mark-compactable verb; no host exposes one.

The artifact is append-only: never overwrite earlier decisions. Separate each appended decision with a markdown separator (`---`). This entry point's location is known from the pipeline context: `specs/<feature>/CONCLUSIONS.md` alongside `brief.md`. Do not ask the user for a write location. The file is created after the first confirmed decision.

Before the grill concludes, settle the loop terms this task needs and record them as a subsection of `brief.md`, per the `agent-pipeline` rule's Loop Discipline section: the closing bar for `/code-review`/`/ship-review` (which severities block), the frozen scope this task covers (ending "anything else is a follow-up issue, not a finding in this round."), and the round cap (default two). These are decisions, not facts — put them to the user like any other grill question rather than assuming the defaults.

When the grill concludes with shared understanding reached, note that the settled vocabulary in `CONTEXT.md` and any new ADRs are ready to feed into `/speckit-specify` — the spec should use the glossary's canonical terms and must not contradict the ADRs.
