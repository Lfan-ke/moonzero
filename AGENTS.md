`moonzero` assembles microservices for MoonBit — config, resilience middleware, service discovery, tracing, and a Prometheus endpoint — in the shape of go-zero. The portable library lives at the root; `discov/` holds the native drivers that need real I/O.

# Working here

- `moon fmt` before anything else. CI runs `moon fmt && git diff --exit-code`, so an unformatted file fails the build on its own.
- `moon check --target all --deny-warn` is the gate. Warnings are errors, and all four backends (wasm, wasm-gc, js, native) must pass. Run it again after the first round of fixes: a package whose sources do not compile hides the diagnostics in its own test files, so errors surface in waves.
- `moon test --target all` at the root; `moon test --target native` inside `discov/`.
- `moon info` regenerates `pkg.generated.mbti`. If that file does not change, your edit is not visible to anyone depending on this package, which usually means the refactor was safe. If it does change, read the diff before committing — that is the public interface moving. The examples regenerate their own, which is why those are gitignored.
- CI installs the latest moon on every run, so a toolchain that is behind will disagree with it. Upgrade locally rather than pinning.

# Layout

Root is portable and has no async dependency: `config.mbt`, `yaml.mbt`, the resilience middleware (`breaker.mbt`, `maxconns.mbt`, `limits.mbt`, `retry.mbt`), `metrics.mbt`, `tracing.mbt`, `jwt.mbt`, `discovery.mbt`, and the zrpc client. `discov/` is `supported_targets = "native"` and carries the drivers that speak to real etcd, consul and redis over sockets, plus the file-backed registry. Tests sit beside their subject as `*_wbtest.mbt` at the root and `*_test.mbt` under `discov/`; `examples/NN-topic/` are runnable one-file demos.

# Things worth knowing

- Middleware is async — `Middleware` is `(async App) -> async App` — but the root package deliberately does not depend on `moonbitlang/async`, so it cannot host an `async test`. End-to-end middleware tests belong in `discov/`, which already imports async and runs native-only. `maxconns_release_test.mbt` is the pattern to copy.
- Anything holding a resource across a call into user code must release it with `defer`, not with a trailing statement or a `catch` that re-raises. Both skip cancellation, and the compiler's `fragile_catch_all` lint now says so. `max_conns` leaked a permit exactly this way and wedged the limiter shut at 503.
- The tests against real etcd, consul and redis are gated on `MOON_ETCD_TEST`, `MOON_CONSUL_TEST` and `MOON_REDIS_TEST`; without them the suite silently skips those. CI sets them and starts the containers.
- `ConsulHttp` and `RedisConn` are `pub trait`, which in MoonBit is sealed — only this package can implement them. Consumers therefore cannot build a `ConsulClient` or `RedisClient` of their own; the transports in `discov/` are the only implementations.
