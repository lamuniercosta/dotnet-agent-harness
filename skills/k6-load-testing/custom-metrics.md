# Custom Metrics

## Custom Metrics

### Counters

```javascript
import http from 'k6/http';
import { Counter, Trend, Rate, Gauge } from 'k6/metrics';

// Define custom metrics
const myCounter = new Counter('api_calls_total');
const responseTime = new Trend('response_time');
const errorRate = new Rate('error_rate');
const activeUsers = new Gauge('active_users');

export default function () {
  const res = http.get('https://api.example.com/data');
  
  // Increment counter
  myCounter.add(1);
  
  // Add to trend (for percentiles)
  responseTime.add(res.timings.duration);
  
  // Track error rate
  errorRate.add(res.status !== 200);
  
  // Set gauge value
  activeUsers.add(__VU);
  
  // Tagged metrics
  const taggedRes = http.get('https://api.example.com/users', {
    tags: { endpoint: 'users', env: 'prod' },
  });
}
```

---
