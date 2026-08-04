///|
/// Drive each resilience decision core over an explicit clock, so its whole state
/// machine is visible without a running server: the token bucket, the circuit
/// breaker, the request deadline, the max-conns permit pool, and the fixed-window
/// period limiter.
///
///     moon run examples/03-resilience-core
#coverage.skip
fn main {
  // TokenBucket: a burst of `capacity` back-to-back, then empty until it refills.
  let bucket = @moonzero.TokenBucket::new(3.0, burst=3.0, now=0)
  let burst = [
    bucket.allow(0),
    bucket.allow(0),
    bucket.allow(0),
    bucket.allow(0),
  ]
  println("token bucket burst-of-3 then empty: " + bools(burst))
  println("  available after 1s refill: " + bucket.available(1000L).to_string())
  println("  admits again once refilled: " + bucket.allow(1000L).to_string())

  // Breaker: two consecutive failures trip it Open; after the cool-down it admits
  // one HalfOpen probe, and a probe success closes it again.
  let breaker = @moonzero.Breaker::new(
    max_failures=2,
    open_ms=1000L,
    half_open_max=1,
  )
  breaker.record_failure(0L)
  breaker.record_failure(0L)
  println("breaker after 2 failures: " + breaker.state().to_string())
  println("  admits while open (t=500): " + breaker.allow(500L).to_string())
  let probe = breaker.allow(1000L)
  println(
    "  admits half-open probe (t=1000): " +
    probe.to_string() +
    ", state=" +
    breaker.state().to_string(),
  )
  breaker.record_success()
  println("  after probe success: " + breaker.state().to_string())

  // Deadline: a budget measured from a start instant; a non-positive budget never
  // expires (go-zero's disabled-timeout convention).
  let deadline = @moonzero.Deadline::start(500L, 0L)
  println(
    "deadline remaining at t=100: " +
    deadline.remaining(100L).to_string() +
    "ms, expired at t=600: " +
    deadline.expired(600L).to_string(),
  )
  println(
    "  disabled deadline expires: " +
    @moonzero.Deadline::start(0L, 0L).expired(999999L).to_string(),
  )

  // MaxConns: a permit pool that admits up to `max` in flight at once.
  let conns = @moonzero.MaxConns::new(2)
  let taken = [conns.try_acquire(), conns.try_acquire(), conns.try_acquire()]
  println(
    "max-conns(2) three acquires: " +
    bools(taken) +
    ", in_flight=" +
    conns.in_flight().to_string(),
  )
  conns.release()
  println(
    "  after one release, acquire again: " + conns.try_acquire().to_string(),
  )

  // PeriodLimit: a fixed window of `quota` per period, per key.
  let period = @moonzero.PeriodLimit::new(period_secs=1, quota=3)
  let window = [
    period.take("k", 0L),
    period.take("k", 0L),
    period.take("k", 0L),
    period.take("k", 0L),
  ]
  println("period-limit quota-3 window: " + join(window.map(period_name)))
  println(
    "  next window (t=1s) resets: " + period_name(period.take("k", 1000L)),
  )
}

///|
fn period_name(r : @moonzero.PeriodResult) -> String {
  match r {
    PeriodAllowed => "allowed"
    PeriodHitQuota => "hit-quota"
    PeriodOverQuota => "over-quota"
  }
}

///|
fn bools(items : Array[Bool]) -> String {
  join(items.map(b => b.to_string()))
}

///|
fn join(items : Array[String]) -> String {
  let sb = StringBuilder::new()
  sb.write_char('[')
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(items[i])
  }
  sb.write_char(']')
  sb.to_string()
}
