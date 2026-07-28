///|
/// A token-bucket rate limiter (← go-zero's `limit.TokenLimiter`, modelled as a
/// pure in-process counter over an explicit clock instead of Redis+Lua). The
/// bucket holds up to `capacity` tokens and refills continuously at
/// `refill_per_ms` tokens per millisecond; each admitted request spends one
/// token. Because every decision is a function of `(state, now)`, the limiter is
/// exactly testable without a real clock.
pub struct TokenBucket {
  capacity : Double
  refill_per_ms : Double
  mut tokens : Double
  mut last_ms : Int64
}

///|
/// Build a bucket admitting `rate` requests per second on average with room for a
/// `burst` of that many back-to-back (default `burst = rate`). It starts full at
/// time `now`. A non-positive `rate`/`burst` is clamped to a minimum so the
/// bucket always has a defined capacity.
pub fn TokenBucket::new(
  rate : Double,
  burst? : Double = -1.0,
  now? : Int64 = 0,
) -> TokenBucket {
  let cap = if burst <= 0.0 { rate } else { burst }
  let cap = if cap <= 0.0 { 1.0 } else { cap }
  { capacity: cap, refill_per_ms: rate / 1000.0, tokens: cap, last_ms: now }
}

///|
/// Add the tokens accrued since `last_ms` up to `now`, capped at `capacity`. A
/// clock that moves backwards is treated as no elapsed time.
fn TokenBucket::refill(self : TokenBucket, now : Int64) -> Unit {
  let elapsed = now - self.last_ms
  if elapsed > 0L {
    let added = elapsed.to_double() * self.refill_per_ms
    let filled = self.tokens + added
    self.tokens = if filled > self.capacity { self.capacity } else { filled }
    self.last_ms = now
  }
}

///|
/// Try to admit one request at time `now`: refill, then spend a token if one is
/// available. Returns `true` when admitted, `false` when the bucket is empty.
pub fn TokenBucket::allow(self : TokenBucket, now : Int64) -> Bool {
  self.allow_n(1.0, now)
}

///|
/// Try to admit a request costing `n` tokens at time `now`. Returns `false`
/// (spending nothing) when fewer than `n` tokens are available.
pub fn TokenBucket::allow_n(
  self : TokenBucket,
  n : Double,
  now : Int64,
) -> Bool {
  self.refill(now)
  if self.tokens >= n {
    self.tokens = self.tokens - n
    true
  } else {
    false
  }
}

///|
/// The (fractional) number of tokens currently available, after refilling to
/// `now`. Useful for metrics and tests.
pub fn TokenBucket::available(self : TokenBucket, now : Int64) -> Double {
  self.refill(now)
  self.tokens
}

///|
/// The event stream a rejected request receives: a `429 Too Many Requests` with a
/// short plain-text body. A pure value so the limiter's response is testable
/// without driving the async transport.
fn too_many_requests_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(status=429, headers=[
      ("content-type", "text/plain; charset=utf-8"),
    ]),
    @moonasgi.Event::HttpResponseBody(
      body=b"429 Too Many Requests",
      more_body=false,
    ),
  ]
}

///|
/// Rate-limit middleware (← go-zero's `TokenLimitMiddleware`): admit each HTTP
/// request against a shared `TokenBucket` read at `clock.now()`, answering
/// `429 Too Many Requests` when the bucket is empty and otherwise delegating to
/// the wrapped app. The bucket is captured once per assembly, so its state is
/// shared across every request this layer serves. Non-HTTP scopes (lifespan,
/// websocket) pass through untouched.
pub fn rate_limit(bucket : TokenBucket, clock : Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if bucket.allow(clock.now()) {
            inner(scope, receive, send)
          } else {
            for event in too_many_requests_events() {
              send(event)
            }
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}
