# Security

## `fixtures/BadCode` contains deliberate violations

Before reporting anything from that directory: **it is a test fixture and every
flaw in it is intentional.** It exists so CI can prove the gates actually catch
defects rather than merely running.

The fixture deliberately contains:

- a SQL string built by concatenation from a parameter (CA2100)
- `DateTime.Now` in production code (banned via `BannedSymbols.txt`)
- an `async void` method, an unused parameter, an unread field
- a method at cyclomatic complexity 24
- a duplicated block
- a bounds check missing its lower bound
- a boundary no test asserts

`fixtures/BadCode/scripts/apply-fix.ps1` rewrites all of it to its correct form;
CI asserts the gates go red on the broken state and green on the fixed one.

**No vulnerable package is committed anywhere in this repository.** The
supply-chain gate is proven against a canned advisory document
(`fixtures/BadCode/stub-vulnerable.json`) precisely so that a repo about good
practice does not ship a known CVE. See `fixtures/BadCode/README.md` for what
that does and does not cover.

## What this project is, security-wise

A collection of PowerShell scripts, markdown instructions, and configuration.
It runs no service, opens no port, and stores no credentials.

Two things are worth knowing:

**It executes on your machine with your permissions.** `install.ps1` writes into
a target repository, and the gate scripts invoke `dotnet`, `git`, and `gh`.
Read them before running them, as you would any script from the internet.

**The `guard.ps1` hook is a safety net, not a sandbox.** It blocks a specific
list of destructive commands — `rm -rf` of a root or home target, force-push to
a protected branch, deletion of a protected branch via push, `git reset --hard`
to a remote ref, writes into `.git` or build output. It is deliberately narrow, it is not a security boundary, and it
will not stop a determined or novel command. Do not rely on it as your only
protection; your editor's own permission controls are the real gate.

`hooks/Test-Guard.ps1` asserts what it does block, including the escaped-quote
payload that defeats a `grep`-based implementation. If you find a bypass, that
is worth reporting.

## Reporting a vulnerability

Open a GitHub issue for anything in this repository, including a guard bypass.
There is no private disclosure process because there is no deployed service and
no user data — the threat model is "a script you chose to run on your own
machine".

If a finding is genuinely sensitive, say so in the issue without details and a
private channel can be arranged.

## Not in scope

- Findings in `fixtures/BadCode` (see above)
- Vulnerabilities in the tools the gates invoke — report those to
  [Stryker.NET](https://github.com/stryker-mutator/stryker-net), JetBrains,
  or Microsoft as appropriate
- Vulnerabilities in the vendored third-party rules, which are documentation and
  execute nothing (see `NOTICE`)
