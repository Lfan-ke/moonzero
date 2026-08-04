# Examples

Runnable `main` packages that drive the public `@moonzero` API in-process, so no
port is bound and no live etcd/consul/redis is needed. Each prints the actual
results — status codes, decoded bodies, generated wire bytes, round-trips — so
running it proves the feature works.

```bash
moon run examples/07-zrpc                       # portable examples run on any backend
moon run --target native examples/00-metrics    # native-only ones await the async onion
```

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`metrics`](00-metrics/) | Assemble a service behind the metrics middleware, drive requests, and scrape the Prometheus `/metrics` exposition | `metrics`, `ServerMetrics::to_exposition`, `Server::use_` |
| 01 | [`config`](01-config/) | `ServiceConf` from defaults / JSON / YAML, `LogLevel` ordering, raw `yaml_parse` | `ServiceConf::from_json`/`from_yaml`, `LogLevel`, `yaml_parse` |
| 02 | [`middleware`](02-middleware/) | The base onion — CORS, request-id, tracing, structured + request logging, recovery — with its injected response headers and JSON access log | `cors`, `request_id`, `tracing`, `structured_logging`, `logging`, `recovery`, `RequestLog` |
| 03 | [`resilience-core`](03-resilience-core/) | The resilience decision cores over an explicit clock: token bucket, breaker, deadline, max-conns, period limit | `TokenBucket`, `Breaker`, `Deadline`, `MaxConns`, `PeriodLimit` |
| 04 | [`resilience-mw`](04-resilience-mw/) | Each resilience middleware gating a real request: 401 / 429 / 503 / 413 and the admit paths | `auth`, `rate_limit`, `period_limit`, `breaker`, `timeout`, `maxbytes`, `max_conns` |
| 05 | [`jwt-crypto`](05-jwt-crypto/) | SHA-256 / HMAC / constant-time compare, then HS256 sign + verify with the tampered / expired / `alg:none` rejections | `sha256`, `hmac_sha256`, `jwt_sign`, `jwt_verify`, `jwt_authorized`, `base64url_encode` |
| 06 | [`tracing`](06-tracing/) | W3C Trace Context: start a new trace, continue an inbound one, reject a malformed header | `next_trace_context`, `parse_traceparent`, `TraceContext`, `generate_trace_id` |
| 07 | [`zrpc`](07-zrpc/) | A zRPC service with all four cardinalities over the in-process h2c channel, plus the UNIMPLEMENTED an unknown method answers | `RpcServer`, `RpcGroup`, `RpcChannel::call`/`call_server_streaming`/`call_client_streaming`/`open_bidi` |
| 08 | [`discovery`](08-discovery/) | Registries, round-robin / pick-first balancers, a watch + snapshot/restore round-trip, and a load-balanced channel across two instances | `InMemoryRegistry`, `PersistentRegistry`, `RoundRobin`, `Balancer`, `RpcCluster`, `LoadBalancedChannel` |
| 09 | [`shutdown`](09-shutdown/) | The graceful-shutdown gate draining in-flight calls while new ones come back Unavailable | `ShutdownCoordinator`, `RpcServer::dispatch_graceful` |
| 10 | [`etcd`](10-etcd/) | The `etcdserverpb` messages round-tripping, and `EtcdDiscovery` / `EtcdClient` over an in-process mock etcd | `EtcdKeyValue`, `EtcdClient`, `EtcdDiscovery`, `etcd_prefix_end` |
| 11 | [`consul`](11-consul/) | The consul driver's wire surface: the register body, the check id, and the `health/service` parser | `consul_register_body`, `consul_check_id`, `consul_parse_health`, `ConsulResponse` |
| 12 | [`redis`](12-redis/) | The RESP codec: encode a command, decode every RESP2/RESP3 reply shape, stream pipelined replies, build discovery keys | `resp_command`, `RespValue::decode`, `RespReader`, `redis_instance_key` |
| 13 | [`http1`](13-http1/) | The HTTP/1 client codec: build a close-delimited request, parse a response, trim the body to Content-Length | `http1_request`, `http1_parse_response`, `Http1Response` |
| 14 | [`discov-file`](14-discov-file/) | The native `discov` driver over a real file: publish a snapshot, load it, and reload the Put/Delete diff | `@discov.persist_registry`, `@discov.FileRegistry::load`/`reload`/`resolver` |

## Native-only examples

`00-metrics`, `02-middleware`, `04-resilience-mw`, and `14-discov-file` are
`supported_targets = "native"`. The first three await the async `AsgiApp` the
middleware wraps — driving the onion in-process records each request on its
response path exactly as a live server would. `14-discov-file` reads and writes a
real file through `moonbitlang/async`'s fs. The other examples run on every
backend (`wasm`, `wasm-gc`, `js`, `native`).

## A note on the consul / redis client layers

`ConsulClient`/`ConsulDiscovery` and `RedisClient`/`RedisDiscovery` are driven by
the `ConsulHttp` and `RedisConn` transport traits, which are sealed (`pub trait`),
so only moonzero's own package can supply a fake transport. The full
register → resolve → deregister flow over an in-memory fake therefore lives in the
white-box tests (`consul_discovery_wbtest.mbt`, `redis_discovery_wbtest.mbt`);
examples 11 and 12 exercise the request-shaping, parsing, key-layout, and
RESP-codec surface those layers are built on, which is public and runs on every
backend.
