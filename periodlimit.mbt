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
/// A fixed-window rate limiter (← go-zero's `limit.PeriodLimit`, modelled as a pure
/// in-process counter over an explicit clock instead of Redis+Lua). Each key may
/// make up to `quota` requests per `period`; a key's window opens on its first
/// request and resets once `period` has elapsed. It is the counting complement of
/// the continuous `TokenBucket`. Because every decision is a function of
/// `(state, now)`, the limiter is exactly testable without a real clock.
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
/// Fixed-window rate-limit middleware (← go-zero's period-limit guard): account for
/// each HTTP request under `key` and answer `429 Too Many Requests` once the key is
/// over quota for the current window, otherwise delegating to the wrapped app. The
/// limiter is captured once per assembly, so its windows are shared across every
/// request this layer serves. Non-HTTP scopes pass through untouched.
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
