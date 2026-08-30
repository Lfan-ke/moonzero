///|
/// The outcome of a `PeriodLimit.take` (← go-zero's period-limit result codes): a
/// request within quota, the one that reaches it exactly (still admitted), or one
/// beyond it (rejected).
pub(all) enum PeriodResult {
  PeriodAllowed
  PeriodHitQuota
  PeriodOverQuota
} derive(Eq, Debug)

///|
/// A fixed-window rate limiter kept in this process: each key may make up to `quota`
/// requests per `period`; a key's window opens on its first request and resets once
/// `period` has elapsed. It is the counting complement of the continuous
/// `TokenBucket`, and because every decision is a function of `(state, now)` it is
/// exactly testable without a real clock.
///
/// The window is local, so N replicas admit N quotas. `RedisPeriodLimit` is the same
/// limiter with its window in redis and is what a fleet should run; this one is for a
/// single process, and for the fallback a caller wants when redis is unreachable.
pub struct PeriodLimit {
  period_ms : Int64
  quota : Int
  windows : Map[String, (Int64, Int)]
}

///|
/// A limiter admitting `quota` requests per `period_secs` seconds, per key.
pub fn PeriodLimit::new(period_secs~ : Int, quota~ : Int) -> PeriodLimit {
  { period_ms: period_secs.to_int64() * 1000L, quota, windows: Map([]), }
}

///|
/// Account for one request under `key` at `now` and report its outcome. Opens a
/// fresh window if the key's current one has elapsed; `PeriodAllowed` below quota,
/// `PeriodHitQuota` at exactly the quota (the last admitted request), and
/// `PeriodOverQuota` beyond it.
pub fn PeriodLimit::take(
  self : PeriodLimit,
  key : String,
  now : Int64,
) -> PeriodResult {
  let (start, count) = match self.windows.get(key) {
    Some((s, c)) => if now - s >= self.period_ms { (now, 0) } else { (s, c) }
    None => (now, 0)
  }
  let count = count + 1
  self.windows[key] = (start, count)
  if count < self.quota {
    PeriodAllowed
  } else if count == self.quota {
    PeriodHitQuota
  } else {
    PeriodOverQuota
  }
}

///|
/// Fixed-window rate-limit middleware over the process-local limiter: account for each
/// HTTP request under `key` and answer `429 Too Many Requests` once the key is over
/// quota for the current window, otherwise delegating to the wrapped app. The limiter
/// is captured once per assembly, so its windows are shared across every request this
/// layer serves — but only within this process; use `redis_period_limit` to share them
/// across replicas. Non-HTTP scopes pass through untouched.
pub fn period_limit(
  limiter : PeriodLimit,
  clock : Clock,
  key? : String = "global",
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          match limiter.take(key, clock.now()) {
            PeriodOverQuota =>
              for event in too_many_requests_events() {
                send(event)
              }
            _ => inner(scope, receive, send)
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}

///|
/// go-zero's `core/limit/periodscript.lua`, verbatim: `INCRBY` the key, hang the window
/// on it the first time it appears, and answer `1` below quota, `2` exactly at it, `0`
/// past it. Public so a caller can pre-load it, and so a redis double can evaluate the
/// very text the limiter ships.
pub let period_script : String =
  #|-- to be compatible with aliyun redis, we cannot use `local key = KEYS[1]` to reuse the key
  #|local limit = tonumber(ARGV[1])
  #|local window = tonumber(ARGV[2])
  #|local current = redis.call("INCRBY", KEYS[1], 1)
  #|if current == 1 then
  #|    redis.call("expire", KEYS[1], window)
  #|end
  #|if current < limit then
  #|    return 1
  #|elseif current == limit then
  #|    return 2
  #|else
  #|    return 0
  #|end

///|
/// A fixed-window rate limiter whose window lives in redis (← go-zero's
/// `limit.PeriodLimit`). One `INCRBY`-ed counter per key, given a `period`-second expiry
/// the first time it appears, so every replica pointed at the same redis and key draws
/// on one quota instead of each getting its own.
pub struct RedisPeriodLimit {
  client : RedisClient
  script : RedisScript
  period_secs : Int
  quota : Int
  prefix : String
}

///|
/// A limiter admitting `quota` requests per `period_secs` seconds per key, counting in
/// `client`'s redis under `prefix`-prefixed keys.
pub fn RedisPeriodLimit::new(
  client : RedisClient,
  period_secs~ : Int,
  quota~ : Int,
  prefix? : String = "",
) -> RedisPeriodLimit {
  {
    client,
    script: RedisScript::new(period_script),
    period_secs,
    quota,
    prefix,
  }
}

///|
/// Account for one request under `key` and report its outcome, in the same three states
/// the local limiter reports. A code the script cannot have returned, or a reply that is
/// not an integer at all, raises — go-zero answers `Unknown` with `ErrUnknownCode`
/// there, and a caller has to decide what an undecided limiter means.
pub async fn RedisPeriodLimit::take(
  self : RedisPeriodLimit,
  key : String,
) -> PeriodResult raise RedisError {
  let reply = self.script.run(self.client, [@utf8.encode(self.prefix + key)], [
    @utf8.encode(self.quota.to_string()),
    @utf8.encode(self.period_secs.to_string()),
  ])
  match reply {
    Integer(code) =>
      match code {
        0 => PeriodOverQuota
        1 => PeriodAllowed
        2 => PeriodHitQuota
        _ => raise RedisError("unknown period-limit code: " + code.to_string())
      }
    other =>
      raise RedisError("unexpected period-limit reply: " + resp_kind(other))
  }
}

///|
/// Fixed-window rate-limit middleware over a shared redis: `period_limit` with the
/// window in redis, so replicas behind one redis spend one quota between them. A redis
/// that cannot be reached admits the request — the limiter is a guard on the
/// service, not a dependency that should be able to close it.
pub fn redis_period_limit(
  limiter : RedisPeriodLimit,
  key? : String = "global",
) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) => {
          let outcome = limiter.take(key) catch {
            RedisError(_) => PeriodAllowed
          }
          match outcome {
            PeriodOverQuota =>
              for event in too_many_requests_events() {
                send(event)
              }
            _ => inner(scope, receive, send)
          }
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
