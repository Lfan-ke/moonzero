name = "Lfan-ke/moonzero"

version = "0.6.1"

readme = "README.md"

repository = "https://github.com/Lfan-ke/moonzero"

license = "Apache-2.0"

keywords = [
  "go-zero",
  "microservice",
  "server",
  "middleware",
  "moonapi",
  "moonbit",
]

description = "moonzero — a service framework for MoonBit (← go-zero): config-driven assembly of a moonapi application with middleware, producing a runnable moonasgi AsgiApp. v0.6.1 runs real unary, server/client-streaming, and bidirectional zRPC calls over moonrpc's h2c transport (an in-process RpcChannel drives HPACK HEADERS + length-prefixed DATA + grpc-status trailers through the H2Server engine), graceful shutdown draining in-flight calls, a persisted, watchable etcd v3-shaped registry (watch, events_since catch-up, snapshot/restore) with round-robin/pick-first balancers and a load-balanced client, real file-backed registry I/O over moonbitlang/async's fs with a live filesystem watcher (native discov driver), request metrics (counter + latency histogram), and W3C traceparent propagation."

import {
  "Lfan-ke/moonapi@0.1.0",
  "Lfan-ke/moonasgi@0.1.0",
  "Lfan-ke/moonrpc@0.5.0",
  "moonbitlang/async@0.20.3",
}
