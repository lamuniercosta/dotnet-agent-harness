# Data Handling

## Data Handling

### CSV Data Source

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

// Option 1: Load once, shared across VUs
const users = new SharedArray('users', function () {
  return open('./users.csv').split('\n').slice(1).map(line => {
    const [email, password] = line.split(',');
    return { email, password };
  });
});

export default function () {
  const user = users[__VU % users.length];
  
  const res = http.post('https://api.example.com/login',
    JSON.stringify({ email: user.email, password: user.password })
  );
  
  check(res, { 'login successful': (r) => r.status === 200 });
}
```

### JSON Data Source

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';

const products = new SharedArray('products', function () {
  return JSON.parse(open('./products.json'));
});

export default function () {
  const product = products[Math.floor(Math.random() * products.length)];
  
  const res = http.get(`https://api.example.com/products/${product.id}`);
  
  check(res, { 'product found': (r) => r.status === 200 });
}
```

---
