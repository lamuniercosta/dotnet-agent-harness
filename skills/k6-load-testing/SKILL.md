---
name: k6-load-testing
description: "Comprehensive k6 load testing skill for API, browser, and scalability testing. Write realistic load scenarios, analyze results, and integrate with CI/CD."
category: testing
risk: safe
source: community
date_added: "2026-03-13"
author: Kairo Official
tags: [k6, load-testing, performance, api-testing, ci-cd]
tools: [claude, cursor, gemini]
---

# k6 Load Testing

Adapted from the community `k6-load-testing` skill ([davila7/claude-code-templates](https://github.com/davila7/claude-code-templates), MIT). Place load scripts under `tests/load/`, run against local/staging (never production without approval), and pass secrets via `__ENV` (e.g. `k6 run -e API_TOKEN=… script.js`).

## Overview

k6 is a modern, developer-centric load testing tool that helps you write and execute performance tests for HTTP APIs, WebSocket endpoints, and browser scenarios. This skill provides comprehensive guidance on writing realistic load tests, configuring test scenarios (smoke, load, stress, spike, soak), analyzing results, and integrating with CI/CD pipelines.

Use this skill when you need to validate system performance, identify bottlenecks, ensure SLA compliance, or catch performance regressions before deployment.

---

## When to Use This Skill

- Use when you need to load test HTTP APIs, WebSocket endpoints, or browser scenarios
- Use when setting up performance regression tests in CI/CD
- Use when analyzing system behavior under various load conditions
- Use when comparing performance between code changes
- Use when validating SLA requirements and performance budgets

---

### Test Types

| Type | Use Case | Configuration |
|------|----------|---------------|
| Smoke Test | Verify basic functionality | Low VUs (1-5), short duration |
| Load Test | Normal expected load | Target VUs based on traffic |
| Stress Test | Find breaking point | Ramp beyond capacity |
| Spike Test | Sudden traffic spikes | Rapid increase/decrease |
| Soak Test | Long-term stability | Extended duration |

## Best Practices

- **Start with smoke test**: Verify test works with 1-5 VUs before scaling up
- **Use realistic data**: Parameterize with real user data and behaviors
- **Set meaningful thresholds**: Match your SLA and business requirements
- **Warm up systems**: Include ramp-up time in stages
- **Monitor external dependencies**: Track not just your APIs but downstream services
- **Use tags**: Tag requests for granular analysis (`tags: { endpoint: 'users' }`)
- **Keep tests focused**: One test file per scenario for clarity

---

## Common Pitfalls

- **Problem:** Tests pass locally but fail in CI
  **Solution:** Ensure CI environment has similar resources and network conditions

- **Problem:** Inconsistent results between runs
  **Solution:** Check for external dependencies, random data, or test data pollution

- **Problem:** k6 runs out of memory
  **Solution:** Use ` SharedArray` for large data, reduce VUs, or use `--max-memory` flag

- **Problem:** Thresholds too strict
  **Solution:** Start with relaxed thresholds, tighten based on historical data

---

## Related Skills

- `@performance-engineer` - For broader performance optimization
- `@api-testing-observability-api-mock` - For API mocking during testing
- `@application-performance-performance-optimization` - For performance optimization

---

## Additional Resources

- [k6 Documentation](https://k6.io/docs/)
- [k6 Examples](https://github.com/grafana/k6/tree/master/examples)
- [k6 Load Testing Guides](https://k6.io/guides/)
- [k6 Cloud](https://k6.io/cloud/)

## Topics

- **k6 Basics** — installation and quick start. Read ./basics.md in this skill's directory
- **Test Configuration** — common options and test types. Read ./test-config.md in this skill's directory
- **HTTP Testing** — basic requests, chaining, and parameterized testing. Read ./http-testing.md in this skill's directory
- **Browser Testing** — k6 browser scenarios. Read ./browser-testing.md in this skill's directory
- **WebSocket Testing** — WebSocket connect, message, and close flows. Read ./websocket-testing.md in this skill's directory
- **Data Handling** — CSV and JSON data sources. Read ./data-handling.md in this skill's directory
- **Thresholds & SLA** — basic and advanced thresholds. Read ./thresholds.md in this skill's directory
- **Custom Metrics** — counters, trends, rates, and gauges. Read ./custom-metrics.md in this skill's directory
- **CI/CD Integration** — GitHub Actions and GitLab CI. Read ./ci-cd.md in this skill's directory
- **Results Analysis** — built-in reports and interpreting results. Read ./results.md in this skill's directory
- **Examples** — basic API load test and auth plus parameterization. Read ./examples.md in this skill's directory
