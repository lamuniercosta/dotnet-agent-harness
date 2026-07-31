# fixtures/BadCode — the proof

A small solution containing **one deliberate violation per gate**. CI installs the
harness against it and asserts every gate exits non-zero on the broken code and
zero after the fix.

This tests the thing that actually matters: that the gates **catch** things.
A CI job proving the scripts *run* would be nearly worthless — a gate that
executes and reports a pass it did not earn is the exact failure mode the whole
harness is built to prevent.

## The violations

| Gate | Violation | Where |
|---|---|---|
| Cyclomatic complexity | a method at complexity ~20, well over the 15 ceiling | `Bad/TangledRouter.cs` |
| Banned symbols (RS0030) | `DateTime.Now` in production code | `Bad/Clock.cs` |
| Roslyn analyzers | unused parameter, unread private field, `async void` | `Bad/Sloppy.cs` |
| Security analyzers | SQL built by string concatenation from a parameter (CA2100) | `Bad/UserLookup.cs` |
| InspectCode | a duplicated block across two methods | `Bad/Duplicated.cs` |
| Mutation (Stryker) | a boundary with no test asserting it — the mutant survives | `Bad/Discount.cs` |
| Vulnerable packages | **stubbed** — see below | `stub-vulnerable.json` |

## Why the vulnerable-package gate is stubbed

Every other gate is proven against real code. This one is not, deliberately.

Proving it "for real" means committing a package with a known CVE to a public
repository. That would raise permanent Dependabot alerts, populate the Security
tab, and trip third-party scanners — on a repo whose entire purpose is to
demonstrate good practice.

So CI feeds `run-vulnerable-packages.ps1` a canned `dotnet list package
--vulnerable --format json` document (`stub-vulnerable.json`) and asserts the
script parses it, classifies severity, and exits 1. That covers the part which
could plausibly break — the parsing and threshold logic. It does **not** cover
the `dotnet` CLI invocation itself, and this README says so rather than
implying end-to-end coverage that does not exist.

## Two commits, not two directories

The fixture is verified across a pair of git states:

- **broken** — `Bad/` as committed here; every gate must exit **1**
- **fixed** — `scripts/apply-fix.ps1` rewrites `Bad/` to its clean form; every
  gate must exit **0**

Asserting only the red state would let a gate that *always* fails pass CI. Both
directions are required: a gate must fire on bad code **and** stay quiet on good
code. A gate that cries wolf gets disabled, which is just a slower way of not
having it.
