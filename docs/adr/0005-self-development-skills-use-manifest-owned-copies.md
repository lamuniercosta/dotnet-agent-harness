# Self-development skills use manifest-owned discovery copies

> **Superseded by [ADR 0012](0012-the-harness-does-not-project-its-own-skills.md).**
> The bootstrap this ADR describes has been removed. The reasoning below is kept
> as the record of why it existed and what replaced it.

The harness repository needs to exercise the same skill invocation surface as a consumer without turning generated host projections into authored sources. A repo-local self-development bootstrap therefore creates ignored Claude and Codex discovery copies from canonical skills and records their ownership in an ignored manifest outside both discovery trees. Refresh and cleanup may change only manifest-owned names; the `start-issue` authored overrides and all foreign skills remain outside that ownership, while an unowned canonical-name collision aborts before any mutation. This preserves the full self-install refusal while making self-development delivery reproducible and safe.
