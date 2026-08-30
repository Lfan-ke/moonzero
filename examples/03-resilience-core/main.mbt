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

  // Breaker: Google SRE throttling. A roll of 1.0 loses no draw, so the ratio
  // printed here is the formula alone; the first five failures are free.
  let clock = @moonzero.ManualClock::new().as_clock()
  let breaker = @moonzero.Breaker::new(clock, rand=() => 1.0)
  let ratios = []
  for _ in 0..<8 {
    reject(breaker)
    ratios.push(breaker.drop_ratio().to_string())
  }
  println("breaker drop ratio, failure by failure: " + join(ratios))

  // The same eight failures under a roll of 0.0, which loses every draw: once
  // the ratio leaves zero the breaker starts shedding calls outright.
  let shedding = @moonzero.Breaker::new(clock, rand=() => 0.0)
  for _ in 0..<8 {
    reject(shedding)
  }
  println(
    "  sheds the next call: " +
    (shedding.allow() is None).to_string() +
    ", ratio=" +
    shedding.drop_ratio().to_string(),
  )

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
/// Take one call through the breaker and settle it as a failure, or let the
/// throttle shed it.
fn reject(b : @moonzero.Breaker) -> Unit {
  match b.allow() {
    Some(p) => p.reject()
    None => ()
  }
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
  let sb = StringBuilder()
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
