`moonzero` assembles microservices for MoonBit — config, resilience middleware, service discovery, tracing, and a Prometheus endpoint — in the shape of go-zero. The portable library lives at the root; `discov/` holds the native drivers that need real I/O.

# Working here

- `moon fmt` before anything else. CI runs `moon fmt && git diff --exit-code`, so an unformatted file fails the build on its own.
- `moon check --target all --deny-warn` is the gate. Warnings are errors, and all four backends (wasm, wasm-gc, js, native) must pass. Run it again after the first round of fixes: a package whose sources do not compile hides the diagnostics in its own test files, so errors surface in waves.
- `moon test --target all` at the root; `moon test --target native` inside `discov/`.
- `moon info` regenerates `pkg.generated.mbti`. If that file does not change, your edit is not visible to anyone depending on this package, which usually means the refactor was safe. If it does change, read the diff before committing — that is the public interface moving. `moon info` skips a package pinned to `supported_targets = "native"`, so `discov/` has no tracked interface and its drift is invisible to review. The examples regenerate their own, which is why those are gitignored.
- CI installs the latest moon on every run, so a toolchain that is behind will disagree with it. Upgrade locally rather than pinning.

# Layout

Root is portable and has no async dependency: `config.mbt`, `yaml.mbt`, the resilience middleware (`breaker.mbt`, `maxconns.mbt`, `limits.mbt`, `periodlimit.mbt`, `ratelimit.mbt`), `metrics.mbt`, `tracing.mbt`, `jwt.mbt`, `discovery.mbt`, and the zrpc client. `discov/` is `supported_targets = "native"` and carries the drivers that speak to real etcd, consul and redis over sockets, plus the file-backed registry. Tests sit beside their subject as `*_wbtest.mbt` at the root and `*_test.mbt` under `discov/`; `examples/NN-topic/` are runnable one-file demos.

# Things worth knowing

- Middleware is async — `Middleware` is `(async App) -> async App` — but the root package deliberately does not depend on `moonbitlang/async`, so it cannot host an `async test`. End-to-end middleware tests belong in `discov/`, which already imports async and runs native-only. `maxconns_release_test.mbt` is the pattern to copy.
- Anything holding a resource across a call into user code must release it with `defer`, not with a trailing statement or a `catch` that re-raises. Both skip cancellation, and the compiler's `fragile_catch_all` lint now says so. `max_conns` leaked a permit exactly this way and wedged the limiter shut at 503.
- The tests against real etcd, consul and redis are gated on `MOON_ETCD_TEST`, `MOON_CONSUL_TEST` and `MOON_REDIS_TEST`; without them the suite silently skips those. CI sets them and starts the containers.
- `ConsulHttp` and `RedisConn` are `pub trait`, which in MoonBit is sealed — only this package can implement them, and right now the only implementations are the test fakes. `discov/`'s `ConsulSocket` and `RedisSocket` are real network clients but do not implement those traits, because the traits are synchronous and the sockets are not. So `ConsulClient`, `RedisClient`, `ConsulDiscovery` and `RedisDiscovery` cannot reach a real server today; closing that means making the traits async and implementing them in `discov/`, or moving the clients there.
- The resilience primitives are not ports of go-zero's algorithms and their doc comments say so: the breaker is a consecutive-failure state machine rather than go-zero's probabilistic rolling-window `googleBreaker`, and both limiters are process-local rather than Redis-Lua-backed, so N replicas admit N times the quota.
