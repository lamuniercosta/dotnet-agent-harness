---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADRs and glossary) as we go. Run before /speckit-specify so the spec is written from settled vocabulary.
disable-model-invocation: true
---

Run a `/grilling` session, using the `/domain-modeling` skill.

When the grill concludes with shared understanding reached, note that the settled vocabulary in `CONTEXT.md` and any new ADRs are ready to feed into `/speckit-specify` — the spec should use the glossary's canonical terms and must not contradict the ADRs.
