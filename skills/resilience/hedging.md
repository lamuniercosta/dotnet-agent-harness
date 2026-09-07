# Hedging (Parallel Requests)

```csharp
builder.Services.AddHttpClient<ISearchService, SearchServiceClient>()
    .AddResilienceHandler("search-hedging", builder =>
    {
        builder.AddHedging(new HttpHedgingStrategyOptions
        {
            MaxHedgedAttempts = 2,
            Delay = TimeSpan.FromMilliseconds(500) // Send parallel request after 500ms
        });
        builder.AddTimeout(TimeSpan.FromSeconds(3));
    });
```

**Why**: Hedging sends a parallel request if the first hasn't responded within the delay. Use for latency-sensitive reads where you can tolerate duplicate work.
