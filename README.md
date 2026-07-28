<div align="center">

# moonzero

**A service framework for MoonBit — `← go-zero`.**

[![Check and Test](https://github.com/Lfan-ke/moonzero/actions/workflows/ci.yml/badge.svg)](https://github.com/Lfan-ke/moonzero/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoonzero-brightgreen)](https://mooncakes.io/docs/Lfan-ke/moonzero)

</div>

`moonzero` is the integration layer of the **moon\*** suite — the role `go-zero` plays for Go. It assembles a [`moonapi`](https://github.com/Lfan-ke/moonapi) application from config, wraps it in middleware, and produces a runnable [`moonasgi`](https://github.com/Lfan-ke/moonasgi) `AsgiApp` that a server (`mooncat`) runs. It depends only on `moonapi` + `moonasgi`, so it stays backend-agnostic.

```mermaid
flowchart LR
  conf["ServiceConf"] --> srv["**moonzero** Server"]
  api["moonapi App"] --> srv
  mw["middleware<br/>(logging, ...)"] --> srv
  srv -->|"to_asgi()"| asgi(["moonasgi AsgiApp"])
  asgi --> cat["mooncat serves it"]
```

## Quickstart

```moonbit
let app = @moonapi.App::new()
let api = @moonzero.Group::new(app, "/api/v1")     // prefix a set of routes
api.get("/ping", _ctx => @moonapi.text(200, "pong"))

let conf = @moonzero.ServiceConf::new(
  name="greet", host="127.0.0.1", port=8888, timeout_ms=3000, log_level=Info,
)
let server = @moonzero.Server::new(conf, app)
  .use_(@moonzero.cors(@moonzero.CorsConf::new()))   // Access-Control-* headers
  .use_(@moonzero.request_id())                      // x-request-id per request
  .use_(@moonzero.recovery)                           // 500 instead of a panic
  .use_(@moonzero.logging)

server.describe()        // "greet listening on 127.0.0.1:8888"
@mooncat.serve(server.to_asgi(), host=conf.host, port=conf.port)   // run it (native)
```

Verified across all backends (`wasm`, `wasm-gc`, `js`, `native`) in CI, 0 warnings under `--deny-warn`.

## Resilience middleware

Beyond the base onion (logging, recovery, CORS, request-id), moonzero ships go-zero's resilience set, each modelled as a pure decision core over an injected [`Clock`](./clock.mbt) so its timing is exactly testable:

```moonbit
let clock = @moonzero.Clock::new(() => now_ms())     // real time at the async edge
let server = @moonzero.Server::new(conf, app)
  .use_(@moonzero.maxbytes(1 << 20))                                   // 413 over 1 MiB
  .use_(@moonzero.rate_limit(@moonzero.TokenBucket::new(100.0), clock))// 429 when empty
  .use_(@moonzero.breaker(@moonzero.Breaker::new(), clock))            // 503 while open
  .use_(@moonzero.timeout(3000L, clock))                              // deadline
  .use_(@moonzero.structured_logging(clock))                          // one JSON line/req
```

- **`rate_limit`** — a [`TokenBucket`](./ratelimit.mbt): admits a burst, refills continuously, answers `429` when empty.
- **`breaker`** — a [`Breaker`](./breaker.mbt) closed/open/half-open state machine: trips after K consecutive failures, fails fast with `503`, then admits half-open probes to test recovery.
- **`timeout`** — a [`Deadline`](./limits.mbt) enforced on the response path. Preemptively aborting a hung handler needs racing it against a timer (`@async.any`) under the native runtime; that race is wired at the async server edge, the deadline core is portable and tested.
- **`maxbytes`** — rejects a request whose declared `Content-Length` exceeds the limit with `413`.
- **`structured_logging`** — a [`RequestLog`](./logging.mbt) rendered as one JSON line per request (method, path, status, duration, request-id, client-ip, user-agent).

## Auth, YAML config, and zRPC over the h2c transport

```moonbit
// JWT HS256 — self-built SHA-256/HMAC (verified against NIST/RFC vectors)
let token = @moonzero.jwt_sign(
  Map([("sub", Json::string("alice")), ("exp", Json::number(1893456000.0))]),
  "topsecret",
)
let server = @moonzero.Server::new(conf, app)
  .use_(@moonzero.auth("topsecret", clock))   // 401 unless a valid Bearer JWT
  .use_(@moonzero.tracing())                  // W3C traceparent in/out
  .use_(@moonzero.metrics(m, clock))          // request counter + latency histogram

// YAML config — the etc/*.yaml format go-zero ships, same lenient defaults as JSON
let conf = @moonzero.ServiceConf::from_yaml("name: greet\nport: 9000\nlog_level: error\n")

// A real unary zRPC call over moonrpc's h2c transport
let rpc = @moonzero.RpcServer::new(@moonzero.RpcServerConf::new(name="greeter", port=9090))
rpc.group("hello.Greeter").register("SayHello", req => handle(req))
let ch = @moonzero.RpcChannel::connect(rpc)
ch.call("/hello.Greeter/SayHello", request)    // Ok(reply) | Err(status)
```

- **`jwt_sign` / `jwt_verify`** — compact HS256 tokens on a [self-built SHA-256 + HMAC-SHA256](./crypto.mbt), signatures compared in constant time, `exp`/`nbf` enforced, and the `alg:none` downgrade refused. Interop-verified against the canonical jwt.io token.
- **`auth`** — the [middleware](./auth.mbt) that requires `Authorization: Bearer <jwt>` and answers `401` for an absent, malformed, tampered, or expired token.
- **`ServiceConf::from_yaml`** — a [minimal-subset YAML parser](./yaml.mbt) (block maps, nesting, sequences, typed scalars, comments) feeding the same field reader as the JSON loader, so both formats agree field-for-field.
- **`RpcServer` / `RpcGroup`** — [config-driven zRPC groups](./rpc.mbt) that register [`moonrpc`](https://github.com/Lfan-ke/moonrpc) `Method` handlers by gRPC path.
- **`RpcChannel`** — a [client over the h2c transport](./zrpc.mbt): `to_h2` turns the registered handlers into a `moonrpc` `H2Server`, and a `call` runs a real unary exchange through it — HPACK-coded HEADERS, a length-prefixed DATA frame, and the `grpc-status` trailer read back off the reply. A call to an unregistered path comes back `UNIMPLEMENTED`, the trailers-only response a gRPC server sends for an unknown method.

## Discovery, metrics, tracing

```moonbit
// Service registry (etcd-shaped): register instances, resolve, balance
let reg = @moonzero.InMemoryRegistry::new()
reg.register("greeter", @moonzero.Endpoint::new("10.0.0.1", 9090))
reg.register("greeter", @moonzero.Endpoint::new("10.0.0.2", 9090))
let lb = @moonzero.RoundRobin::new()
@moonzero.resolve_one(reg, "greeter", lb)      // Some(10.0.0.1:9090), then .2, cycling

// Metrics read out for a /metrics scrape after serving
let m = @moonzero.ServerMetrics::new()
m.requests().value("GET /ping 200")            // request count for that label
m.latency().mean()                             // mean request latency, ms
```

- **`InMemoryRegistry`** — a [service registry](./registry.mbt) shaped like go-zero's etcd `discov` store: a `service -> instance -> endpoint` map with a monotonic store revision a watcher can compare against. `RoundRobin` and `pick_first` balancers select an endpoint from a resolved set; an etcd- or consul-backed store with the same `resolve` shape drops in unchanged.
- **`ServerMetrics`** — a [`CounterVec`](./metrics.mbt) of per-method/route/status request tallies and a cumulative latency `Histogram` (Prometheus `le` buckets, sum, count), driven by the `metrics` middleware that times each request on the clock.
- **`tracing`** — [trace-id propagation](./tracing.mbt): continue an inbound W3C `traceparent` or start a new trace, mint a child span, and stamp `traceparent` + `x-trace-id` onto the response.

## Roadmap (transliterating go-zero)

Typed config (JSON + YAML with defaults, timeout + log level) + service assembly + the base middleware onion (logging, recovery, CORS, request-id) + the resilience set (timeout, rate-limit, breaker, maxbytes, structured logging) + route groups + JWT auth + zRPC groups with a real h2c round-trip + a service registry with balancers + request metrics + trace-id propagation are here. Next: server/client streaming once `moonrpc` lands it, an etcd/consul-backed registry, and `moonctl`-driven scaffolding of a full `moonzero` service from a spec.

## License

Apache-2.0.
