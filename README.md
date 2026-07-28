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
app.get("/ping", _ctx => @moonapi.text(200, "pong"))

let conf = @moonzero.ServiceConf::new(name="greet", host="127.0.0.1", port=8888)
let server = @moonzero.Server::new(conf, app).use_(@moonzero.logging)

server.describe()        // "greet listening on 127.0.0.1:8888"
@mooncat.serve(server.to_asgi(), host=conf.host, port=conf.port)   // run it (native)
```

Verified across all backends (`wasm`, `wasm-gc`, `js`, `native`) in CI, 0 warnings under `--deny-warn`.

## Roadmap (transliterating go-zero)

Config + service assembly + a middleware onion are here. Next, feature-by-feature: typed config loading (YAML/JSON), a richer middleware set (recovery, CORS, timeout, rate-limit, auth), structured logging and metrics, RPC service groups over `moonrpc`, and service discovery / registry — plus `moonctl`-driven scaffolding of a full `moonzero` service from a spec.

## License

Apache-2.0.
