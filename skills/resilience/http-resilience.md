# HTTP Client Resilience

## Patterns

### HTTP Client Resilience (Recommended Default)

```csharp
// Program.cs — Standard resilience handler covers 90% of use cases
builder.Services.AddHttpClient<IPaymentGateway, PaymentGatewayClient>(client =>
{
    client.BaseAddress = new Uri("https://api.payments.example.com");
})
.AddStandardResilienceHandler(); // Retry + circuit breaker + timeout out of the box

// That's it. The standard handler configures:
// - Retry: 3 attempts, exponential backoff, jitter
// - Circuit breaker: 10% failure ratio over 30s sampling, 30s break
// - Attempt timeout: 10s per attempt
// - Total request timeout: 30s
```

**Why**: `AddStandardResilienceHandler()` from `Microsoft.Extensions.Http.Resilience` applies production-ready defaults. Override only when you need different thresholds.

### Custom HTTP Resilience Configuration

```csharp
builder.Services.AddHttpClient<ICatalogService, CatalogServiceClient>(client =>
{
    client.BaseAddress = new Uri("https://api.catalog.example.com");
})
.AddResilienceHandler("catalog", builder =>
{
    // Total timeout — outermost, caps total elapsed time
    builder.AddTimeout(TimeSpan.FromSeconds(15));

    // Retry — exponential backoff with jitter
    builder.AddRetry(new HttpRetryStrategyOptions
    {
        MaxRetryAttempts = 3,
        BackoffType = DelayBackoffType.Exponential,
        UseJitter = true,
        Delay = TimeSpan.FromMilliseconds(500),
        ShouldHandle = static args => ValueTask.FromResult(
            args.Outcome.Result?.StatusCode is HttpStatusCode.RequestTimeout
                or HttpStatusCode.TooManyRequests
                or HttpStatusCode.ServiceUnavailable
                || args.Outcome.Exception is HttpRequestException)
    });

    // Circuit breaker — prevent cascading failures
    builder.AddCircuitBreaker(new HttpCircuitBreakerStrategyOptions
    {
        FailureRatio = 0.5,
        SamplingDuration = TimeSpan.FromSeconds(10),
        MinimumThroughput = 10,
        BreakDuration = TimeSpan.FromSeconds(30)
    });

    // Per-attempt timeout — innermost
    builder.AddTimeout(TimeSpan.FromSeconds(5));
});
```

**Why**: Named resilience handlers let you tune per-service. The order matters: total timeout > retry > circuit breaker > attempt timeout.
