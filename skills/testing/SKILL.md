---
name: testing
description: >
  Testing strategy for .NET 10 applications. Covers xUnit v3, WebApplicationFactory
  for integration tests, Testcontainers for real database testing, Verify for
  snapshot testing, and the AAA pattern.
  Load this skill when writing tests, setting up test infrastructure, reviewing
  test coverage, or when the user mentions "test", "xUnit", "WebApplicationFactory",
  "Testcontainers", "integration test", "unit test", "bUnit", "snapshot test",
  "Verify", "test coverage", "AAA pattern", "WireMock", or "FakeTimeProvider".
---

# Testing

Adapted from [codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit) (MIT).

## Map to the repo's stack first (read first)

The examples below use EF Core + Postgres illustratively. **Detect what the repo actually uses before writing a line** — run `/convention-learner`, or read one existing test in each test project. Fill this table in for the repo at hand:

| Concern | What to look for | Common choices |
|---|---|---|
| Test projects | the `tests/` layout and what each project is for | unit (+ `[Trait("Category","Property")]` for FsCheck), integration, acceptance |
| Assertions | the dominant style in existing tests | xUnit `Assert`, FluentAssertions, Shouldly |
| Mocks | the substitution library already referenced | NSubstitute, Moq, FakeItEasy |
| Real DB in tests | how integration tests get a database | Testcontainers (preferred), a shared instance (avoid) |
| External HTTP | how outbound calls are faked | WireMock.NET, a stub `HttpMessageHandler` |
| Integration host | how the app is booted in-process | `WebApplicationFactory<Program>` |
| Time | how `TimeProvider` is controlled | `FakeTimeProvider` (`Microsoft.Extensions.TimeProvider.Testing`) |

**Match the existing choice — do not introduce a second one.** Two assertion libraries or two mocking libraries in one suite is a convention failure the `code-review` Standards axis will flag, and it is the most common way generated tests read as foreign.

Two rules that hold regardless of stack:

- **Never mock the data-access driver for behaviour that depends on real query translation or serialisation.** A mocked collection or `DbSet` will happily lie about ID handling, type mapping, and what the query engine actually does. Use a real engine via Testcontainers.
- Section comments `// arrange` `// act` `// assert` are the one exception to the no-comments rule in `coding-conventions`.

Acceptance scenarios, when the repo uses them, come from `/gherkin`.

## Core Principles

1. **Integration tests are the highest-value tests** — A single `WebApplicationFactory` test covers routing, binding, validation, business logic, and persistence in one shot. Start here before writing unit tests.
2. **Real databases in tests** — Use Testcontainers to spin up real PostgreSQL/SQL Server instances. In-memory providers hide real bugs (transactions, constraints, SQL generation).
3. **AAA pattern is mandatory** — Every test has three clearly separated sections: Arrange, Act, Assert. No mixing.
4. **Test behavior, not implementation** — Tests should survive refactoring. Test what the system does, not how it does it.

## Decision Guide

| Scenario | Recommendation |
|----------|---------------|
| Testing an API endpoint | `WebApplicationFactory` integration test |
| Testing business logic in isolation | Unit test with fakes/stubs |
| Database-dependent tests | Testcontainers (real DB) |
| Complex response validation | Verify snapshot testing |
| Time-dependent logic | `FakeTimeProvider` |
| External API dependency | `WireMock.Net` or `HttpMessageHandler` stub |
| Parameterized test cases | `[Theory]` with `[InlineData]` or `[MemberData]` |
| Test data setup | Builder pattern |
| Shared expensive fixture | `IClassFixture<T>` with `IAsyncLifetime` |

## Topics

- **Integration Tests** — WebApplicationFactory and Testcontainers. Read ./integration-tests.md in this skill's directory
- **xUnit v3 Basics** — xUnit v3 basics and test naming convention. Read ./xunit-basics.md in this skill's directory
- **Verify Snapshot Testing** — snapshot testing with Verify. Read ./snapshot-testing.md in this skill's directory
- **Test Data Builders** — builder pattern for test data. Read ./test-data-builders.md in this skill's directory
- **Testing Time-Dependent Code** — TimeProvider and FakeTimeProvider. Read ./time-testing.md in this skill's directory
- **Anti-patterns** — in-memory DB, implementation details, shared state, assertion-free tests. Read ./anti-patterns.md in this skill's directory
