# Testing Time-Dependent Code

Use `TimeProvider` (built into .NET 8+) and `FakeTimeProvider` from `Microsoft.Extensions.TimeProvider.Testing`.

```csharp
[Fact]
public async Task ExpireOrders_MarksOldPendingOrdersAsExpired()
{
    // Arrange
    var clock = new FakeTimeProvider(new DateTimeOffset(2025, 6, 1, 0, 0, 0, TimeSpan.Zero));
    var db = CreateDb();
    var order = Order.Create("customer-1", items, clock.GetUtcNow());
    db.Orders.Add(order);
    await db.SaveChangesAsync();

    // Advance time past expiry threshold
    clock.Advance(TimeSpan.FromDays(31));

    var handler = new ExpireOrders.Handler(db, clock);

    // Act
    await handler.Handle(new ExpireOrders.Command(), CancellationToken.None);

    // Assert
    var updated = await db.Orders.FindAsync(order.Id);
    Assert.Equal(OrderStatus.Expired, updated!.Status);
}
```
