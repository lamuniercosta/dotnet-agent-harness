# Non-HTTP Resilience Pipeline

### Non-HTTP Resilience Pipeline

```csharp
// For database calls, message queues, or any non-HTTP operation
builder.Services.AddResiliencePipeline("database", builder =>
{
    builder
        .AddRetry(new RetryStrategyOptions
        {
            MaxRetryAttempts = 3,
            BackoffType = DelayBackoffType.Exponential,
            Delay = TimeSpan.FromMilliseconds(200),
            ShouldHandle = new PredicateBuilder()
                .Handle<TimeoutException>()
                .Handle<InvalidOperationException>(ex =>
                    ex.Message.Contains("deadlock", StringComparison.OrdinalIgnoreCase))
        })
        .AddTimeout(TimeSpan.FromSeconds(10));
});

// Inject and use
public sealed class OrderRepository(
    AppDbContext db,
    [FromKeyedServices("database")] ResiliencePipeline pipeline)
{
    public async Task<Order?> GetByIdAsync(Guid id, CancellationToken ct)
    {
        return await pipeline.ExecuteAsync(
            async token => await db.Orders.FindAsync([id], token),
            ct);
    }
}
```

**Why**: `AddResiliencePipeline` registers a named pipeline in DI. Inject with `[FromKeyedServices]` for clean, testable code.

### Typed Resilience Pipeline

```csharp
// When the operation returns a specific type, use ResiliencePipeline<T>
builder.Services.AddResiliencePipeline<string, HttpResponseMessage>("external-api", builder =>
{
    builder
        .AddFallback(new FallbackStrategyOptions<HttpResponseMessage>
        {
            FallbackAction = static args =>
            {
                var response = new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent("{\"status\":\"degraded\",\"data\":[]}")
                };
                return Outcome.FromResultAsValueTask(response);
            },
            ShouldHandle = static args => ValueTask.FromResult(
                args.Outcome.Exception is not null
                || args.Outcome.Result?.IsSuccessStatusCode == false)
        })
        .AddRetry(new RetryStrategyOptions<HttpResponseMessage>
        {
            MaxRetryAttempts = 2,
            Delay = TimeSpan.FromMilliseconds(500)
        })
        .AddTimeout(TimeSpan.FromSeconds(5));
});
```

**Why**: Typed pipelines let you add fallback strategies that return a default value when all retries are exhausted — critical for graceful degradation.
