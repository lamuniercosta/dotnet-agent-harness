# Thresholds & SLA

## Thresholds & SLA

### Basic Thresholds

```javascript
export const options = {
  vus: 50,
  duration: '2m',
  
  thresholds: {
    // Response time thresholds
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    
    // Error rate threshold
    http_req_failed: ['rate<0.01'],
    
    // Throughput threshold
    http_reqs: ['rate>100'],
  },
};
```

### Advanced Thresholds

```javascript
export const options = {
  thresholds: {
    // Multiple thresholds on same metric
    http_req_duration: [
      'p(90)<300',   // 90th percentile < 300ms
      'p(95)<500',  // 95th percentile < 500ms
      'p(99)<1000', // 99th percentile < 1s
      'avg<200',    // average < 200ms
    ],
    
    // Custom metrics
    my_custom_metric: ['avg<100'],
    
    // Abort on threshold failure
    'http_req_duration{method:GET}': ['p(95)<300'],
  },
};
```

---
