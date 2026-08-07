# InspectCode gate exit contract

Source: GitHub issue #41

## Problem

Three gate paths report a pass without performing or completing their intended verification:

- JetBrains InspectCode exits `3` because no files match the requested solution scope.
- InspectCode exits successfully but does not produce its promised SARIF report.
- The vulnerable-package gate is disabled through `gates.vulnerablePackages.fail: false` and performs no scan.

## Shared understanding

The harness only reports a pass after a gate verifies its intended scope and finds no blocking issue. The outcomes for these paths are therefore:

| Path | Verdict | Exit |
|---|---|---:|
| InspectCode exit `3` | Skipped: the resolved scope matched no files | `2` |
| InspectCode exit `0` without SARIF | Could not run: the expected evidence is absent | `1` |
| `gates.vulnerablePackages.fail: false` | Skipped: the gate is disabled | `2` |

The `fail` key remains the vulnerable-package gate's legacy disable switch. Renaming it or changing it to mean "scan but do not fail" would break existing configuration semantics and is outside this fix.

## Constraints

- Preserve successful InspectCode analysis with a readable SARIF report as a pass.
- Preserve blocking InspectCode findings as failures.
- Keep regression tests offline; they must not restore or invoke the real JetBrains tool.
- Keep the packaged gate scripts and the installed BadCode fixture copies behaviorally identical.

## Acceptance checks

- A simulated InspectCode exit `3` returns `2` and says `SKIPPED`.
- A simulated InspectCode exit `0` without SARIF returns `1` and says `GATE COULD NOT RUN`.
- A disabled vulnerable-package gate returns `2` and says `SKIPPED`.
- Existing opposite-direction gate checks remain green.
