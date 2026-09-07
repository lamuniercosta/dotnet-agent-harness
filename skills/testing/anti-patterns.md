# Anti-patterns

## Anti-patterns

### Don't Use In-Memory Database for Integration Tests

```csharp
// BAD — hides real SQL behavior, transactions, constraints
services.AddDbContext<AppDbContext>(options =>
    options.UseInMemoryDatabase("TestDb"));

// GOOD — Testcontainers with real database
services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(testContainer.GetConnectionString()));
```

### Don't Test Implementation Details

```csharp
// BAD — testing that a specific repository method was called
mock.Verify(x => x.AddAsync(It.IsAny<Order>()), Times.Once);
mock.Verify(x => x.SaveChangesAsync(), Times.Once);

// GOOD — test the observable outcome
var order = await db.Orders.FindAsync(orderId);
Assert.NotNull(order);
Assert.Equal(OrderStatus.Created, order.Status);
```

### Don't Share Mutable State Between Tests

```csharp
// BAD — static shared state
private static readonly AppDbContext SharedDb = CreateDb();

// GOOD — fresh state per test (or use IAsyncLifetime for shared fixtures)
private AppDbContext CreateDb() => new(new DbContextOptionsBuilder<AppDbContext>()...);
```

### Don't Write Assertion-Free Tests

```csharp
// BAD — no assertion, only checks it doesn't throw
[Fact]
public async Task CreateOrder_Works()
{
    await service.CreateAsync(request);
    // "it didn't throw, so it works!" — NO
}

// GOOD — assert the expected outcome
[Fact]
public async Task CreateOrder_PersistsOrderToDatabase()
{
    var result = await service.CreateAsync(request);

    var persisted = await db.Orders.FindAsync(result.Value.Id);
    Assert.NotNull(persisted);
    Assert.Equal(request.CustomerId, persisted.CustomerId);
}
```
