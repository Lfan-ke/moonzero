///|
/// The three states of a circuit breaker (← go-zero's `breaker` package). A
/// `Closed` breaker lets traffic through; after too many failures it trips
/// `Open` and fails fast; once its cool-down elapses it goes `HalfOpen` and lets
/// a few probe requests through to test recovery.
pub(all) enum BreakerState {
  Closed
  Open
  HalfOpen
} derive(Eq)

///|
/// The state's lowercase name, for logs and metrics.
pub fn BreakerState::to_string(self : BreakerState) -> String {
  match self {
    Closed => "closed"
    Open => "open"
    HalfOpen => "half-open"
  }
}

///|
/// A circuit breaker as an explicit open/half-open/closed state machine over a
/// clock (← go-zero's `breaker.Breaker`; go-zero's default is Google's SRE
/// adaptive algorithm, but the canonical state machine is the faithful,
/// testable core and is exposed here). Trips after `max_failures` consecutive
/// failures, stays `Open` for `open_ms`, then admits up to `half_open_max`
/// probes; one probe success closes it, one probe failure re-opens it.
pub struct Breaker {
  max_failures : Int
  open_ms : Int64
  half_open_max : Int
  mut state : BreakerState
  mut failures : Int
  mut opened_at : Int64
  mut probes : Int
}

///|
/// Build a closed breaker that trips after `max_failures` consecutive failures
/// (default `5`), stays open for `open_ms` milliseconds (default `5000`), and
/// admits `half_open_max` probes while half-open (default `1`).
pub fn Breaker::new(
  max_failures? : Int = 5,
  open_ms? : Int64 = 5000L,
  half_open_max? : Int = 1,
) -> Breaker {
  {
    max_failures,
    open_ms,
    half_open_max,
    state: Closed,
    failures: 0,
    opened_at: 0L,
    probes: 0,
  }
}

///|
/// The breaker's current state (after any pending `Open`→`HalfOpen` transition
/// is applied by `allow`).
pub fn Breaker::state(self : Breaker) -> BreakerState {
  self.state
}

///|
/// Decide whether a request may proceed at time `now`, advancing the state
/// machine as a side effect:
///
/// * `Closed` — always admitted.
/// * `Open` — rejected until `open_ms` has elapsed since it tripped, at which
///   point it moves to `HalfOpen` and admits this request as the first probe.
/// * `HalfOpen` — admitted while fewer than `half_open_max` probes are
///   outstanding, otherwise rejected.
///
/// Returns `true` to admit, `false` to fail fast.
pub fn Breaker::allow(self : Breaker, now : Int64) -> Bool {
  match self.state {
    Closed => true
    Open =>
      if now - self.opened_at >= self.open_ms {
        self.state = HalfOpen
        self.probes = 1
        true
      } else {
        false
      }
    HalfOpen =>
      if self.probes < self.half_open_max {
        self.probes = self.probes + 1
        true
      } else {
        false
      }
  }
}

///|
/// Record that an admitted request succeeded. In `Closed` it resets the failure
/// streak; in `HalfOpen` a probe success closes the breaker.
pub fn Breaker::record_success(self : Breaker) -> Unit {
  match self.state {
    HalfOpen => {
      self.state = Closed
      self.failures = 0
      self.probes = 0
    }
    _ => self.failures = 0
  }
}

///|
/// Record that an admitted request failed at time `now`. In `Closed` it extends
/// the failure streak and trips `Open` once it reaches `max_failures`; a
/// `HalfOpen` probe failure re-opens the breaker immediately.
pub fn Breaker::record_failure(self : Breaker, now : Int64) -> Unit {
  match self.state {
    Closed => {
      self.failures = self.failures + 1
      if self.failures >= self.max_failures {
        self.state = Open
        self.opened_at = now
      }
    }
    HalfOpen => {
      self.state = Open
      self.opened_at = now
      self.probes = 0
    }
    Open => ()
  }
}

///|
/// The event stream a request rejected by an open breaker receives: a `503
/// Service Unavailable` with a short plain-text body. A pure value so the
/// breaker's response is testable without driving the async transport.
fn service_unavailable_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(
      status=503,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
    @moonasgi.Event::HttpResponseBody(
      body=b"503 Service Unavailable",
      more_body=false,
    ),
  ]
}

///|
/// Circuit-breaker middleware (← go-zero's `breaker` interceptor): gate each HTTP
/// request through a shared `Breaker`. When the breaker admits the request, the
/// outbound `HttpResponseStart` status is observed — a `5xx` (or a raised
/// failure) is recorded as a failure, anything else as a success, driving the
/// state machine. When the breaker is open, the request is failed fast with
/// `503 Service Unavailable` without touching the wrapped app. Non-HTTP scopes
/// pass through untouched.
pub fn breaker(b : Breaker, clock : Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if b.allow(clock.now()) {
            let status : Ref[Int] = { val: 200, }
            let observed : @moonasgi.Send = event => {
              match event {
                HttpResponseStart(status=s, headers~, trailers~) => {
                  status.val = s
                  send(
                    @moonasgi.Event::HttpResponseStart(
                      status=s,
                      headers~,
                      trailers~,
                    ),
                  )
                }
                other => send(other)
              }
            }
            errdefer b.record_failure(clock.now())
            inner(scope, receive, observed)
            if status.val >= 500 {
              b.record_failure(clock.now())
            } else {
              b.record_success()
            }
          } else {
            for event in service_unavailable_events() {
              send(event)
            }
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}
