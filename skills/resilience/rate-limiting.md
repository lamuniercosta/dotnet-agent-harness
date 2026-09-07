# Rate Limiting (.NET Built-in)

.NET provides built-in rate limiting middleware via `AddRateLimiter()` — no external packages needed. Algorithms: `AddFixedWindowLimiter`, `AddSlidingWindowLimiter`, `AddTokenBucketLimiter`, `AddConcurrencyLimiter`.

```csharp
builder.Services.AddRateLimiter(options =>
{
    options.AddFixedWindowLimiter("fixed", opt =>
    {
        opt.PermitLimit = 100;
        opt.Window = TimeSpan.FromSeconds(60);
        opt.QueueLimit = 0;
    });

    // Always return ProblemDetails with Retry-After on 429
    options.OnRejected = async (context, ct) =>
    {
        context.HttpContext.Response.StatusCode = StatusCodes.Status429TooManyRequests;
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
            context.HttpContext.Response.Headers.RetryAfter =
                ((int)retryAfter.TotalSeconds).ToString();
        await context.HttpContext.Response.WriteAsJsonAsync(
            new ProblemDetails { Title = "Too many requests", Status = 429 }, ct);
    };
});

app.UseRateLimiter();
app.MapGet("/api/orders", ListOrders).RequireRateLimiting("fixed");
```
