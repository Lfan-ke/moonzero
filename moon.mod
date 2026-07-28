name = "Lfan-ke/moonzero"

version = "0.5.0"

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

description = "moonzero — a service framework for MoonBit (← go-zero): config-driven assembly of a moonapi application with middleware, producing a runnable moonasgi AsgiApp. v0.5 runs a real unary zRPC call over moonrpc's h2c transport (an in-process RpcChannel drives HPACK HEADERS + length-prefixed DATA + grpc-status trailers through the H2Server engine), and adds an etcd-shaped service registry with round-robin/pick-first balancers, request metrics (counter + latency histogram), and W3C traceparent propagation."

import {
  "Lfan-ke/moonapi@0.1.0",
  "Lfan-ke/moonasgi@0.1.0",
  "Lfan-ke/moonrpc@0.4.0",
}
