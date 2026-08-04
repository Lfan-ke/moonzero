# Examples

Runnable `main` packages that use the public `@moonzero` API. Each drives the
onion in-process, so no port is bound.

```bash
moon run --target native examples/00-metrics
```

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`metrics`](00-metrics/) | Assemble a service behind the metrics middleware, drive a couple of requests, and scrape the Prometheus `/metrics` exposition | `App::new`, `Group::get`, `ServiceConf::new`, `Server::use_`, `metrics`, `Clock::new`, `ServerMetrics::to_exposition` |

`00-metrics` is native-only: it awaits the async `AsgiApp` the middleware wraps,
so the metrics middleware records each request on its response path exactly as it
would under a live server. The exposition it prints is the body a Prometheus
server reads from `/metrics`:

```text
# TYPE http_server_requests_duration_ms histogram
...
http_server_requests_duration_ms_count 2
# TYPE http_server_requests_code_total counter
http_server_requests_code_total{request="GET /api/v1/ping 200"} 2
```
