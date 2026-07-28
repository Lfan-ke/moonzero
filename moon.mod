name = "Lfan-ke/moonzero"

version = "0.4.0"

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

description = "moonzero — a service framework for MoonBit (← go-zero): config-driven assembly of a moonapi application with middleware, producing a runnable moonasgi AsgiApp. v0.4 adds JWT HS256 auth (self-built SHA-256/HMAC), a minimal-subset YAML config loader, and config-driven zRPC service groups over moonrpc."

import {
  "Lfan-ke/moonapi@0.1.0",
  "Lfan-ke/moonasgi@0.1.0",
  "Lfan-ke/moonrpc@0.2.0",
}
