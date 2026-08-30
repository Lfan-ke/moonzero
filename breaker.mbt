///|
/// Google SRE's client-side throttling constants, the values go-zero ships.
/// `k = 1.5` leaves a backend alone until more than a third of its traffic is
/// failing; `min_k` is the floor `k` decays to under a sustained failure run;
/// `protection` is the traffic every service gets for free, which keeps a quiet
/// service from throttling itself over two bad calls; and after `force_pass_ms`
/// with nothing at all getting through, one call goes past the roll regardless
/// so a recovered backend is noticed.
let k : Double = 1.5

///|
let min_k : Double = 1.1

///|
let protection : Double = 5.0

///|
let force_pass_ms : Int64 = 1000L

///|
/// The window folded the way go-zero's `history` folds it. `failing` and
/// `working` are *trailing runs*, not totals: a bucket that saw both a success
/// and a failure ends both runs, and an idle bucket ends neither.
priv struct Health {
  mut accepts : Int64
  mut total : Int64
  mut failing : Int64
  mut working : Int64
}

///|
/// The unscaled shed fraction. Non-positive means the window is healthy enough
/// to admit everything.
fn Health::ratio(self : Health, buckets : Int) -> Double {
  let w = k - (k - min_k) * self.failing.to_double() / buckets.to_double()
  let weighted = (if w > min_k { w } else { min_k }) * self.accepts.to_double()
  (self.total.to_double() - protection - weighted) /
  (self.total + 1L).to_double()
}

///|
/// The factor that eases the throttle off as clean buckets pile up: `1.0` with
/// nothing working, `0.0` once every bucket in the window is clean.
fn Health::recovery(self : Health, buckets : Int) -> Double {
  (buckets.to_double() - self.working.to_double()) / buckets.to_double()
}

///|
/// Google SRE's client-side throttling breaker (← go-zero's `googleBreaker`,
/// the algorithm behind every breaker it hands out). There is no open/closed
/// state machine and no failure streak: the breaker keeps a rolling `Window` of
/// call outcomes and sheds a *fraction* of new calls, so a struggling backend
/// keeps receiving as much load as it can still serve rather than being cut off
/// wholesale and then flooded again on recovery.
///
/// With `accepts` successes out of `total` calls in the window, `failing` the
/// run of all-failure buckets at the head of the window and `working` the run of
/// all-success ones:
///
/// ```text
/// w     = k - (k - min_k) * failing / buckets
/// drop  = (total - protection - max(w, min_k) * accepts) / (total + 1)
/// drop *= (buckets - working) / buckets
/// ```
///
/// A non-positive `drop` admits everything, which is the whole healthy case. A
/// sustained failure run decays `w` towards `min_k`, so past successes count for
/// less and the throttle bites harder; a run of clean buckets scales `drop` back
/// down as the backend recovers.
///
/// Both sources of nondeterminism are injected — `clock` for time, `rand` for
/// the shed roll — so every decision is reproducible in a test.
pub struct Breaker {
  win : Window
  clock : Clock
  roll : () -> Double
  mut last_pass : Int64?
}

///|
/// A breaker over a `buckets` × `bucket_ms` window (go-zero's ten seconds in
/// forty slices by default) reading time from `clock`. `rand` supplies the shed
/// roll as a draw from `[0, 1)`; omit it and the breaker draws from a
/// system-seeded generator, pass one to fix the decisions.
pub fn Breaker::new(
  clock : Clock,
  rand? : () -> Double,
  buckets? : Int = 40,
  bucket_ms? : Int64 = 250L,
) -> Breaker {
  let roll = match rand {
    Some(f) => f
    None => {
      let src = @random.Rand::new()
      () => src.double()
    }
  }
  {
    win: Window::new(size=buckets, bucket_ms~, now=clock.now()),
    clock,
    roll,
    last_pass: None,
  }
}

///|
fn Breaker::health(self : Breaker, now : Int64) -> Health {
  let h = Health::{ accepts: 0L, total: 0L, failing: 0L, working: 0L, }
  self.win.each(now, b => {
    h.accepts = h.accepts + b.succ
    h.total = h.total + b.sum
    if b.fail > 0L {
      h.working = 0L
    } else if b.succ > 0L {
      h.working = h.working + 1L
    }
    if b.succ > 0L {
      h.failing = 0L
    } else if b.fail > 0L {
      h.failing = h.failing + 1L
    }
  })
  h
}

///|
/// The fraction of new calls the breaker is currently shedding — `0.0` while the
/// window is healthy. The force-pass probe is deliberately not folded in: this
/// is the standing throttle, which is what a dashboard or an alert wants.
pub fn Breaker::drop_ratio(self : Breaker) -> Double {
  let h = self.health(self.clock.now())
  let r = h.ratio(self.win.size)
  if r <= 0.0 {
    0.0
  } else {
    r * h.recovery(self.win.size)
  }
}

///|
/// The shed decision for one call (← go-zero's `accept`), and the only place the
/// roll is drawn.
fn Breaker::accept(self : Breaker) -> Bool {
  let now = self.clock.now()
  let h = self.health(now)
  let r = h.ratio(self.win.size)
  if r <= 0.0 {
    return true
  }
  if self.last_pass is Some(t) && now - t > force_pass_ms {
    self.last_pass = Some(now)
    return true
  }
  if (self.roll)() < r * h.recovery(self.win.size) {
    false
  } else {
    self.last_pass = Some(now)
    true
  }
}

///|
fn Breaker::mark(self : Breaker, o : Outcome) -> Unit {
  self.win.add(o, self.clock.now())
}

///|
/// Ask to make one call. `Some` promise means it may proceed and the caller
/// settles that promise once the call finishes; `None` means the throttle shed
/// it. A shed is recorded too, so a breaker that is dropping never reads back as
/// idle and throttle itself off.
pub fn Breaker::allow(self : Breaker) -> Promise? {
  if self.accept() {
    Some({ b: self, })
  } else {
    self.mark(Drop)
    None
  }
}

///|
/// The receipt for an admitted call (← go-zero's `breaker.Promise`). Exactly one
/// of `accept` / `reject` settles it; until then the window holds no record of
/// how the call went.
pub struct Promise {
  b : Breaker
}

///|
/// Settle the call as a success.
pub fn Promise::accept(self : Promise) -> Unit {
  self.b.mark(Succ)
}

///|
/// Settle the call as a failure.
pub fn Promise::reject(self : Promise) -> Unit {
  self.b.mark(Fail)
}

///|
/// Raised by `Breaker::run` for a call the throttle shed (← go-zero's
/// `ErrServiceUnavailable`).
pub suberror Unavailable

///|
/// Run `req` under the breaker (← go-zero's `Breaker.Do`). A shed call raises
/// `Unavailable` and `req` never runs; otherwise `req` returning settles the
/// promise as a success, and `req` raising settles it as a failure and
/// propagates.
pub fn[T] Breaker::run(self : Breaker, req : () -> T raise) -> T raise {
  guard self.allow() is Some(p) else { raise Unavailable }
  errdefer p.reject()
  let out = req()
  p.accept()
  out
}

///|
/// The event stream a request rejected by the breaker receives: a `503
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
/// Circuit-breaker middleware (← go-zero's `breaker` interceptor): gate each
/// HTTP request through a shared `Breaker`. An admitted request's outbound
/// `HttpResponseStart` status is observed — a `5xx` settles its promise as a
/// failure, anything else as a success, and that is what feeds the window. A
/// shed request is answered `503 Service Unavailable` without the wrapped app
/// running. Non-HTTP scopes pass through untouched.
///
/// The promise starts out a failure and only the observed status makes it a
/// success, on a `defer` — the same shape go-zero's `doReq` uses, so a handler
/// that raises or is cancelled before answering counts against the window
/// instead of quietly not counting at all.
pub fn breaker(b : Breaker) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          match b.allow() {
            Some(p) => {
              let status : Ref[Int] = { val: 500, }
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
              defer (if status.val >= 500 { p.reject() } else { p.accept() })
              inner(scope, receive, observed)
            }
            None =>
              for event in service_unavailable_events() {
                send(event)
              }
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}
