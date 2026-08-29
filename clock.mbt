///|
/// A monotonic time source in **milliseconds**, injected into the resilience
/// middlewares (rate-limit, breaker, timeout) so their timing logic is a pure
/// function of an explicit clock rather than a hidden wall-clock read. go-zero
/// reads `timex.Now()` directly; because that is neither portable across
/// MoonBit's backends nor testable, moonzero threads the clock as a value — the
/// same pattern Go's `clockwork`/`x/time/rate` accept for a `Clock`.
pub struct Clock {
  now_ms : () -> Int64
}

///|
/// Wrap a `now`-in-milliseconds thunk as a `Clock`.
pub fn Clock::new(now_ms : () -> Int64) -> Clock {
  { now_ms, }
}

///|
/// The current time in milliseconds, as reported by the wrapped source.
pub fn Clock::now(self : Clock) -> Int64 {
  (self.now_ms)()
}

///|
/// A deterministic, hand-advanced clock for tests and for driving the rate-limit
/// / breaker cores without a real time source. Wall time is replaced by an
/// explicit `advance`, so a token bucket's refill or a breaker's open window can
/// be exercised exactly.
pub struct ManualClock {
  mut ms : Int64
}

///|
/// A manual clock starting at `start` milliseconds (default `0`).
pub fn ManualClock::new(start? : Int64 = 0) -> ManualClock {
  { ms: start, }
}

///|
/// Move the manual clock forward by `delta` milliseconds.
pub fn ManualClock::advance(self : ManualClock, delta : Int64) -> Unit {
  self.ms = self.ms + delta
}

///|
/// A `Clock` view over this manual clock: reading it reflects every `advance`.
pub fn ManualClock::as_clock(self : ManualClock) -> Clock {
  Clock::new(() => self.ms)
}
