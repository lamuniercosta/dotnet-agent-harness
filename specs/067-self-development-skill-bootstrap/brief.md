# Self-development skill bootstrap

Source: GitHub issue #67

## Problem

The harness authors 25 canonical skills, but its own Claude and Codex discovery trees expose only the repo-local `start-issue` authored overrides. Agents developing the harness must read canonical skill files manually, so the repository cannot exercise the same invocable workflows and Codex adaptations delivered to consumers.

Running the full installer against the harness root is intentionally refused and would also install unrelated consumer artifacts. Committing host discovery copies would create additional authored sources that can drift.

## Shared understanding

Add an explicit repo-local self-development bootstrap at `scripts/local/Sync-SelfSkills.ps1`.

- The default command generates both Claude and Codex discovery copies from the canonical skill tree.
- Claude receives the same canonical form as consumer installation.
- Codex receives the same deterministic host adaptation as consumer installation; the renderer has one implementation shared by both paths.
- One ignored ownership manifest outside the discovery trees records exactly which names the bootstrap generated for each host.
- Refresh may overwrite or remove only manifest-owned discovery copies. A canonical skill removed from the source tree removes its previously owned copies on the next refresh.
- Both `start-issue` authored overrides are permanently reserved and never enter the manifest.
- Foreign skills remain byte-identical. If an unowned directory occupies a canonical name, preflight fails the whole operation before any mutation instead of producing a partial skill surface.
- `Sync-SelfSkills.ps1 -Clean` removes only manifest-owned discovery copies and the manifest.
- An unchanged second run performs no semantic writes and reports that nothing changed.
- Every successful sync or cleanup reports that running Codex and Claude sessions must reload before their available commands change.

## Constraints

- Preserve `install.ps1`'s refusal to install the complete harness into its own root.
- Keep canonical skills as the only authored source of shared workflows.
- Do not require global Codex or Claude installation.
- Do not overwrite or delete an unowned discovery entry, including a same-name collision.
- Keep the source-repository instruction to prefer `start-issue` over `task` for GitHub issue intake.
- Do not add automatic host reload or named-agent delivery.

## Acceptance checks

- A clean checkout generates every canonical Claude and Codex skill with one command.
- Each generated canonical skill matches the corresponding consumer-install output for its host.
- Repeated refresh leaves both authored `start-issue` entries byte-identical.
- Foreign skills in both discovery trees remain byte-identical.
- A same-name foreign collision fails before any generated content or manifest is changed.
- A second unchanged refresh reports no semantic changes.
- Removing a canonical source removes only its manifest-owned discovery copies on refresh.
- `-Clean` removes only manifest-owned copies and leaves authored overrides and foreign skills untouched.
- Existing install-artifact and self-test suites remain green.
- After host reload, `$verify` resolves in Codex and `/verify` resolves in Claude Code from this repository.
