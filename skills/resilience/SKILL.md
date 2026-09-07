---
name: resilience
description: >
  Resilience patterns for .NET 10 applications using Polly v8.
  Covers retry, circuit breaker, timeout, fallback, rate limiter, hedging,
  and composing resilience pipelines.
  Load this skill when implementing retry logic, circuit breakers, handling
  transient failures, or when the user mentions "Polly", "resilience",
  "retry", "circuit breaker", "timeout", "fallback", "rate limit",
  "hedging", "transient fault", "HttpClient resilience", or "resilience pipeline".
---

# Resilience

Adapted from [codewithmukesh/dotnet-claude-kit](https://github.com/codewithmukesh/dotnet-claude-kit) (MIT).

**Find out who already owns retry before adding any.** The most common resilience defect is *doubled* retry: a Polly pipeline wrapped around a transport that already retries and dead-letters on its own. Message brokers (Azure Service Bus, RabbitMQ, SQS), managed queue triggers, and most cloud SDKs have built-in retry policies — wrapping those in Polly multiplies the attempt count and turns a transient blip into a thundering herd.

Before writing a pipeline, check the repo's messaging/infrastructure docs and the SDK defaults, then apply the Polly v8 patterns below **only to outbound calls the application itself owns**: HTTP clients, database drivers without their own retry, and third-party libraries you call directly. Say in the PR which layer owns retry for the path you touched.

## Core Principles

1. **Polly v8 resilience pipelines, not v7 policies** — Polly v8 replaced `Policy` with `ResiliencePipeline`. Never use `PolicyBuilder`, `Policy.Handle<>()`, or `ISyncPolicy`. The new API is composable, type-safe, and integrates natively with `IHttpClientFactory`.
2. **Configure via `AddResilienceHandler`, not manual wrapping** — For HTTP calls, use `Microsoft.Extensions.Http.Resilience` which adds pipelines directly to `HttpClient` via DI. No manual `ExecuteAsync` wrapping.
3. **Compose strategies, don't nest them** — A single `ResiliencePipeline` can chain retry + circuit breaker + timeout. Strategies execute outer-to-inner (first added = outermost). No need for nested try/catch or manual orchestration.
4. **Always set timeouts** — Every external call needs a timeout. Use Polly's `AddTimeout()` as the innermost strategy so it applies per-attempt, and optionally an outer timeout for total elapsed time.
5. **Instrument everything** — Polly v8 emits `Metering` events and supports `TelemetryOptions` for OpenTelemetry. Use them to monitor retry rates, circuit breaker state, and timeout frequency.

## Decision Guide

| Scenario | Strategy | Configuration |
|----------|----------|---------------|
| HTTP calls to external APIs | `AddStandardResilienceHandler()` | Use defaults, override only specific thresholds |
| HTTP with custom thresholds | `AddResilienceHandler("name", ...)` | Named handler with per-service tuning |
| Database / EF Core calls | `AddResiliencePipeline("db", ...)` | Retry on deadlock/timeout, no circuit breaker |
| Message queue publishing | `AddResiliencePipeline("mq", ...)` | Retry with exponential backoff, timeout |
| Latency-sensitive reads | `AddHedging(...)` | Parallel request after delay threshold |
| Graceful degradation | `AddFallback(...)` | Return cached/default value on total failure |
| Per-attempt time limit | `AddTimeout(...)` innermost | 2-10s depending on operation |
| Total operation time limit | `AddTimeout(...)` outermost | Sum of all retries + buffer |
| Non-idempotent writes | Retry with idempotency key | Or no retry — fail fast |
| Read-heavy microservice | Standard handler + hedging | Low latency with redundancy |
| API rate limiting | `AddRateLimiter()` + `RequireRateLimiting()` | Fixed, sliding, or token bucket per endpoint |

## Topics

- **HTTP Client Resilience** — standard handler and custom HTTP configuration. Read ./http-resilience.md in this skill's directory
- **Non-HTTP Resilience Pipeline** — named pipelines and typed pipelines. Read ./non-http-pipelines.md in this skill's directory
- **Hedging** — parallel requests. Read ./hedging.md in this skill's directory
- **Telemetry Integration** — Polly metrics and OpenTelemetry. Read ./telemetry.md in this skill's directory
- **Rate Limiting** — .NET built-in rate limiter. Read ./rate-limiting.md in this skill's directory
- **Anti-patterns** — v7 API, manual wrapping, non-idempotent retries, no monitoring. Read ./anti-patterns.md in this skill's directory
