---
name: grilling
description: Grill the user about a plan, decision, or idea. Use to stress-test thinking, or any 'grill' trigger.
---

Interview me relentlessly about every aspect of this until we reach a shared understanding. Walk down each branch of the decision tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer with implications: I recommend X because Y; the cost is Z. The recommendation reduces round trips; it does not eliminate the decision — put each one to me and wait for my answer.

Ask the questions one at a time, waiting for feedback on each question before continuing. Asking multiple questions at once is bewildering.

If a *fact* can be found by exploring the environment (filesystem, tools, etc.), look it up rather than asking me. The *decisions*, though, are mine — put each one to me and wait for my answer.

Do not act on it until I confirm we have reached a shared understanding.

## Checkpoint-and-compact

After each decision crystallizes and I confirm it, write the conclusions artifact **before** treating the resolved transcript as compactable. Ordering is mandatory, not implied:

1. **Write first.** Append the full decision exchange to the conclusions artifact: every question and answer that led to the decision, my decision, the rationale, and the implications. Do not record only the crystallizing question and answer.
2. **Then declare safe.** Once that write exists, the resolved Q&A is safe for the host's context-management system to summarize away. Artifact existence is the compaction license. This is a declaration to the host, not an active command — do not invoke a mark-compactable verb; no host exposes one.

The artifact is append-only: never overwrite earlier decisions. Separate each appended decision with a markdown separator (`---`).

On the first confirmed decision, state the intended write location and wait for me to confirm or redirect before writing. Default: `CONCLUSIONS.md` in the working directory. The file is created after that first confirmed decision; the location is user-visible, not a background log.
