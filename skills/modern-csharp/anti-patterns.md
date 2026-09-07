# Anti-patterns

## Anti-patterns

### Don't Use Obsolete Patterns When Modern Alternatives Exist

```csharp
// BAD — manual backing field when field keyword works
private string _name;
public string Name
{
    get => _name;
    set => _name = value ?? throw new ArgumentNullException();
}

// BAD — old-style collection initialization
var list = new List<int>() { 1, 2, 3 };

// BAD — Tuple instead of record for domain types
(string Name, decimal Price) product = ("Widget", 9.99m);
// GOOD — record
public record Product(string Name, decimal Price);
```

### Don't Over-pattern-match

```csharp
// BAD — deeply nested pattern that's hard to read
if (order is { Customer: { Address: { Country: { Code: "US" } } } })

// GOOD — extract to a clear method or use sequential checks
if (order.Customer.Address.Country.Code == "US")
```

### Don't Use `var` When the Type Is Not Obvious

```csharp
// BAD — what type is this?
var result = Process(order);

// GOOD — explicit type when not obvious
Result<Order> result = Process(order);
// Also GOOD — var is fine when type is apparent
var orders = new List<Order>();
```
