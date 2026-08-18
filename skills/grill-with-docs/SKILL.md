---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADRs and glossary) as we go. Run before /speckit-specify so the spec is written from settled vocabulary.
disable-model-invocation: true
---

Run a `/grilling` session, using the `/domain-modeling` skill.

Before the grill concludes, settle the loop terms this task needs and record them as a subsection of `brief.md`, per the `agent-pipeline` rule's Loop Discipline section: the closing bar for `/code-review`/`/ship-review` (which severities block), the frozen scope this task covers (ending "anything else is a follow-up issue"), and the round cap (default two). These are decisions, not facts — put them to the user like any other grill question rather than assuming the defaults.

When the grill concludes with shared understanding reached, note that the settled vocabulary in `CONTEXT.md` and any new ADRs are ready to feed into `/speckit-specify` — the spec should use the glossary's canonical terms and must not contradict the ADRs.
