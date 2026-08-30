///|
/// A token-bucket rate limiter kept in this process: the bucket holds up to
/// `capacity` tokens and refills continuously at `refill_per_ms` tokens per
/// millisecond, and each admitted request spends one. Because every decision is a
/// function of `(state, now)`, the limiter is exactly testable without a real
/// clock.
///
/// The bucket is local, so N replicas admit N times the rate. `RedisTokenLimit` is
/// the same limiter with its bucket in redis and is what a fleet should run; this
/// one serves a single process, and is what `RedisTokenLimit` itself falls back to
/// when redis is unreachable (← go-zero's `rescueLimiter`).
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
  { capacity: cap, refill_per_ms: rate / 1000.0, tokens: cap, last_ms: now, }
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
    @moonasgi.Event::HttpResponseStart(
      status=429,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
    @moonasgi.Event::HttpResponseBody(
      body=b"429 Too Many Requests",
      more_body=false,
    ),
  ]
}

///|
/// Rate-limit middleware over the process-local bucket: admit each HTTP request
/// against a shared `TokenBucket` read at `clock.now()`, answering `429 Too Many
/// Requests` when the bucket is empty and otherwise delegating to the wrapped app.
/// The bucket is captured once per assembly, so its state is shared across every
/// request this layer serves — but only within this process; use
/// `redis_rate_limit` to share it across replicas. Non-HTTP scopes (lifespan,
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

///|
/// go-zero's `core/limit/tokenscript.lua`, verbatim: read the bucket and the second it
/// was last touched, refill by the elapsed seconds capped at `capacity`, spend
/// `requested` if that many are there, and write both back under a TTL of two fill
/// times. Public so a caller can pre-load it, and so a redis double can evaluate the
/// very text the limiter ships.
pub let token_script : String =
  #|-- to be compatible with aliyun redis, we cannot use `local key = KEYS[1]` to reuse the key
  #|-- KEYS[1] as tokens_key
  #|-- KEYS[2] as timestamp_key
  #|local rate = tonumber(ARGV[1])
  #|local capacity = tonumber(ARGV[2])
  #|local now = tonumber(ARGV[3])
  #|local requested = tonumber(ARGV[4])
  #|local fill_time = capacity/rate
  #|local ttl = math.floor(fill_time*2)
  #|local last_tokens = tonumber(redis.call("get", KEYS[1]))
  #|if last_tokens == nil then
  #|    last_tokens = capacity
  #|end
  #|
  #|local last_refreshed = tonumber(redis.call("get", KEYS[2]))
  #|if last_refreshed == nil then
  #|    last_refreshed = 0
  #|end
  #|
  #|local delta = math.max(0, now-last_refreshed)
  #|local filled_tokens = math.min(capacity, last_tokens+(delta*rate))
  #|local allowed = filled_tokens >= requested
  #|local new_tokens = filled_tokens
  #|if allowed then
  #|    new_tokens = filled_tokens - requested
  #|end
  #|
  #|redis.call("setex", KEYS[1], ttl, new_tokens)
  #|redis.call("setex", KEYS[2], ttl, now)
  #|
  #|return allowed

///|
/// A token-bucket rate limiter whose bucket lives in redis (← go-zero's
/// `limit.TokenLimiter`). The token count and the second it was last refilled sit under
/// `{key}.tokens` and `{key}.ts`, so every replica pointed at the same redis and key
/// spends from one bucket. When redis cannot be reached the limiter keeps limiting from
/// `rescue`, its process-local `TokenBucket`, the way go-zero drops to its in-process
/// `rescueLimiter` rather than letting an outage open the gate.
pub struct RedisTokenLimit {
  client : RedisClient
  script : RedisScript
  rate : Int
  burst : Int
  token_key : Bytes
  ts_key : Bytes
  rescue : TokenBucket
}

///|
/// A limiter admitting `rate` requests per second with room for a `burst` of that many
/// back-to-back, over the bucket `key` names in `client`'s redis.
pub fn RedisTokenLimit::new(
  client : RedisClient,
  rate~ : Int,
  burst~ : Int,
  key~ : String,
) -> RedisTokenLimit {
  {
    client,
    script: RedisScript::new(token_script),
    rate,
    burst,
    token_key: @utf8.encode("{" + key + "}.tokens"),
    ts_key: @utf8.encode("{" + key + "}.ts"),
    rescue: TokenBucket::new(rate.to_double(), burst=burst.to_double()),
  }
}

///|
/// The process-local bucket this limiter falls back to, so a caller can inspect it.
pub fn RedisTokenLimit::rescue(self : RedisTokenLimit) -> TokenBucket {
  self.rescue
}

///|
/// Try to admit one request at `now_ms`.
pub async fn RedisTokenLimit::allow(
  self : RedisTokenLimit,
  now_ms : Int64,
) -> Bool {
  self.allow_n(1, now_ms)
}

///|
/// Try to admit a request costing `n` tokens at `now_ms`. The script is handed whole
/// seconds because go-zero hands it `now.Unix()`: the shared bucket refills at
/// one-second granularity however finely the clock is read. Lua's `false` arrives as a
/// null reply and its `true` as `1`; anything else, and any redis failure, is served by
/// the local bucket instead.
pub async fn RedisTokenLimit::allow_n(
  self : RedisTokenLimit,
  n : Int,
  now_ms : Int64,
) -> Bool {
  let reply = self.script.run(self.client, [self.token_key, self.ts_key], [
    @utf8.encode(self.rate.to_string()),
    @utf8.encode(self.burst.to_string()),
    @utf8.encode((now_ms / 1000L).to_string()),
    @utf8.encode(n.to_string()),
  ]) catch {
    RedisError(_) => return self.rescue.allow_n(n.to_double(), now_ms)
  }
  match reply {
    Integer(code) => code == 1L
    Null => false
    _ => self.rescue.allow_n(n.to_double(), now_ms)
  }
}

///|
/// Rate-limit middleware over a shared redis: `rate_limit` with the bucket in redis, so
/// replicas behind one redis spend from one bucket. A redis that cannot be reached
/// leaves the limiter running on its local bucket, so the layer keeps limiting either
/// way. Non-HTTP scopes pass through untouched.
pub fn redis_rate_limit(limiter : RedisTokenLimit, clock : Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if limiter.allow(clock.now()) {
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
