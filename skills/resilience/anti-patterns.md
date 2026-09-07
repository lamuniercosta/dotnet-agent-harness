# Anti-patterns

## Anti-patterns

### BAD: Using Polly v7 API

```csharp
// BAD — v7 policy syntax, do not use
var retryPolicy = Policy
    .Handle<HttpRequestException>()
    .WaitAndRetryAsync(3, attempt => TimeSpan.FromSeconds(Math.Pow(2, attempt)));

var response = await retryPolicy.ExecuteAsync(() => httpClient.GetAsync("/api/data"));
```

### GOOD: Polly v8 Resilience Pipeline

```csharp
// GOOD — v8 pipeline via DI
builder.Services.AddHttpClient<IDataService, DataServiceClient>()
    .AddStandardResilienceHandler();
```

---

### BAD: Wrapping Every Call Manually

```csharp
// BAD — manual resilience per call site
public async Task<Order> GetOrderAsync(Guid id)
{
    try
    {
        return await _pipeline.ExecuteAsync(async ct =>
            await _httpClient.GetFromJsonAsync<Order>($"/orders/{id}", ct));
    }
    catch (TimeoutRejectedException)
    {
        return Order.Empty;
    }
    catch (BrokenCircuitException)
    {
        return Order.Empty;
    }
}
```

### GOOD: Pipeline Handles Everything via HttpClient DI

```csharp
// GOOD — resilience is configured at the HttpClient level
public async Task<Order?> GetOrderAsync(Guid id, CancellationToken ct)
{
    var response = await _httpClient.GetAsync($"/orders/{id}", ct);
    if (!response.IsSuccessStatusCode) return null;
    return await response.Content.ReadFromJsonAsync<Order>(ct);
}
```

---

### BAD: Retry on Non-Idempotent Operations

```csharp
// BAD — retrying a POST that creates a resource risks duplicates
builder.AddRetry(new RetryStrategyOptions
{
    MaxRetryAttempts = 5 // This will create 5 orders on transient failures!
});
```

### GOOD: Retry Only Idempotent Operations or Use Idempotency Keys

```csharp
// GOOD — use idempotency key header for non-idempotent operations
builder.AddRetry(new HttpRetryStrategyOptions
{
    MaxRetryAttempts = 3,
    ShouldHandle = static args => ValueTask.FromResult(
        args.Outcome.Result?.StatusCode is HttpStatusCode.RequestTimeout
            or HttpStatusCode.ServiceUnavailable)
});

// Pair with idempotency key in the request
httpClient.DefaultRequestHeaders.Add("Idempotency-Key", Guid.NewGuid().ToString());
```

---

### BAD: Circuit Breaker Without Monitoring

```csharp
// BAD — circuit breaker with no visibility into state changes
builder.AddCircuitBreaker(new CircuitBreakerStrategyOptions());
// How do you know when it trips? You don't.
```

### GOOD: Circuit Breaker with Telemetry

```csharp
// GOOD — Polly v8 metrics captured via OpenTelemetry
builder.Services.AddOpenTelemetry()
    .WithMetrics(metrics => metrics.AddMeter("Polly"));

// Dashboard alerts on: polly.circuit_breaker.state = Open
```
