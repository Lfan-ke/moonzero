///|
/// A request deadline (← go-zero's `timeout` middleware's `context.WithTimeout`):
/// a budget in milliseconds measured from a start instant on the shared clock.
/// A `budget_ms <= 0` means "no deadline" and never expires — go-zero's
/// convention for a disabled timeout.
pub struct Deadline {
  budget_ms : Int64
  started_ms : Int64
}

///|
/// Start a deadline of `budget_ms` milliseconds at time `now`.
pub fn Deadline::start(budget_ms : Int64, now : Int64) -> Deadline {
  { budget_ms, started_ms: now }
}

///|
/// Whether the deadline has passed at time `now`. A non-positive budget never
/// expires.
pub fn Deadline::expired(self : Deadline, now : Int64) -> Bool {
  self.budget_ms > 0L && now - self.started_ms >= self.budget_ms
}

///|
/// Milliseconds left before the deadline at time `now` (never negative); `-1`
/// for a disabled (non-positive-budget) deadline, which has no finite remaining.
pub fn Deadline::remaining(self : Deadline, now : Int64) -> Int64 {
  if self.budget_ms <= 0L {
    -1L
  } else {
    let left = self.budget_ms - (now - self.started_ms)
    if left < 0L {
      0L
    } else {
      left
    }
  }
}

///|
/// The event stream a timed-out request receives: a `503 Service Unavailable`
/// with go-zero's plain-text timeout body. (go-zero's timeout middleware answers
/// `503`.) A pure value so the response is testable without the async transport.
fn timeout_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(status=503, headers=[
      ("content-type", "text/plain; charset=utf-8"),
    ]),
    @moonasgi.Event::HttpResponseBody(body=b"service timeout", more_body=false),
  ]
}

///|
/// Timeout middleware (← go-zero's `TimeoutHandler`): establish a per-request
/// `Deadline` of `budget_ms` at `clock.now()` for the wrapped app.
///
/// **Async boundary (faithful model).** *Preemptively* aborting an in-flight
/// handler the instant its deadline fires requires racing the handler against a
/// timer and cancelling the loser — in MoonBit that is `@async.any([handler,
/// timer])` with structured cancellation, which only runs under the native async
/// runtime and cannot be driven synchronously. What this middleware does
/// portably: it installs the deadline and enforces it on the response path — if
/// the handler blows its budget before emitting its first event, the client
/// receives a `503` timeout (from `timeout_events`) and the late response is
/// suppressed. The remaining gap (a handler that hangs and never emits) is closed
/// by the race/cancel wired at the async server edge. A `budget_ms <= 0` disables
/// the timeout, passing straight through.
pub fn timeout(budget_ms : Int64, clock : Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) => {
          let deadline = Deadline::start(budget_ms, clock.now())
          let done : Ref[Bool] = { val: false }
          let guarded : @moonasgi.Send = event => {
            if done.val {
              // deadline already answered — drop the handler's late output
              ()
            } else if deadline.expired(clock.now()) {
              done.val = true
              for e in timeout_events() {
                send(e)
              }
            } else {
              send(event)
            }
          }
          inner(scope, receive, guarded)
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}

///|
/// Parse a non-negative decimal string to `Int`, returning `None` for an empty
/// string or any non-digit character. Used to read `Content-Length`; core has no
/// portable integer parser, so it is hand-written.
fn parse_uint(s : String) -> Int? {
  if s.length() == 0 {
    return None
  }
  let mut acc = 0
  for i in 0..<s.length() {
    let c = s[i].to_int()
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    acc = acc * 10 + (c - '0'.to_int())
  }
  Some(acc)
}

///|
/// Whether an HTTP scope's declared `Content-Length` exceeds `limit` bytes. A
/// missing or unparseable length is treated as *not* exceeding (go-zero's
/// `MaxBytesHandler` likewise enforces on the declared/streamed size). The header
/// name is matched case-insensitively.
fn content_length_exceeds(scope : @moonasgi.Scope, limit : Int) -> Bool {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0.to_lower() == "content-length" {
          match parse_uint(pair.1) {
            Some(n) => return n > limit
            None => return false
          }
        }
      }
      false
    }
    _ => false
  }
}

///|
/// The event stream an over-limit request receives: a `413 Payload Too Large`
/// with a short plain-text body. A pure value, testable without the transport.
fn payload_too_large_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(status=413, headers=[
      ("content-type", "text/plain; charset=utf-8"),
    ]),
    @moonasgi.Event::HttpResponseBody(
      body=b"413 Payload Too Large",
      more_body=false,
    ),
  ]
}

///|
/// Max-bytes middleware (← go-zero's `MaxBytesHandler`): reject any HTTP request
/// whose declared `Content-Length` exceeds `limit` bytes with `413 Payload Too
/// Large`, before the wrapped app runs. A `limit <= 0` disables the check. Non-
/// HTTP scopes pass through untouched.
pub fn maxbytes(limit : Int) -> Middleware {
  inner => {
    (scope, receive, send) => {
      if limit > 0 && content_length_exceeds(scope, limit) {
        for event in payload_too_large_events() {
          send(event)
        }
      } else {
        inner(scope, receive, send)
      }
    }
  }
}
