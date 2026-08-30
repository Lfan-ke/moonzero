///|
/// An app that answers with `status` and an empty body.
fn responder(status : Int) -> @moonasgi.AsgiApp {
  (_s, _r, snd) => {
    snd(@moonasgi.Event::HttpResponseStart(status~, headers=[], trailers=false))
    snd(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
  }
}

///|
async fn drive(app : @moonasgi.AsgiApp) -> Array[@moonasgi.Event] {
  let sent : Array[@moonasgi.Event] = []
  app(plain_scope(), fn() { @moonasgi.Event::HttpDisconnect }, fn(e) {
    sent.push(e)
  })
  sent
}

///|
fn status_of(events : Array[@moonasgi.Event]) -> Int {
  for e in events {
    match e {
      HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
/// The middleware is what feeds the window, so the status it reads off the wire
/// has to land on the right side of the promise.
async test "breaker middleware reads 5xx as a failure and 2xx as a success" {
  let clock = @moonzero.Clock::new(() => 0L)
  // 1.0 loses no draw, so nothing here is shed and every request reaches the app
  let b = @moonzero.Breaker::new(clock, rand=() => 1.0)
  let failing = @moonzero.breaker(b)(responder(503))
  for _ in 0..<6 {
    assert_eq(status_of(drive(failing)), 503)
  }
  assert_eq(b.drop_ratio(), 1.0 / 7.0)
  let healthy = @moonzero.breaker(b)(responder(200))
  assert_eq(status_of(drive(healthy)), 200)
  // that one success is worth k = 1.5 against the six failures
  assert_eq(b.drop_ratio(), (7.0 - 5.0 - 1.5) / 8.0)
}

///|
/// A handler that raises never reaches a status line. Settled by a trailing
/// statement it would count as nothing at all, and a backend failing that way
/// would never throttle.
async test "breaker middleware records a handler that raises as a failure" {
  let clock = @moonzero.Clock::new(() => 0L)
  let b = @moonzero.Breaker::new(clock, rand=() => 1.0)
  let app = @moonzero.breaker(b)((_s, _r, _snd) => raise InnerFailed)
  for _ in 0..<6 {
    try drive(app) |> ignore catch {
      InnerFailed => ()
      _ => fail("expected InnerFailed")
    } noraise {
      _ => fail("the inner app must raise")
    }
  }
  assert_eq(b.drop_ratio(), 1.0 / 7.0)
}

///|
async test "breaker middleware answers 503 without running the app once shedding" {
  let clock = @moonzero.Clock::new(() => 0L)
  // 0.0 wins every draw, so the throttle sheds the moment the ratio leaves zero
  let b = @moonzero.Breaker::new(clock, rand=() => 0.0)
  let ran : Ref[Int] = { val: 0, }
  let app = @moonzero.breaker(b)((_s, _r, snd) => {
    ran.val = ran.val + 1
    snd(
      @moonasgi.Event::HttpResponseStart(status=503, headers=[], trailers=false),
    )
  })
  for _ in 0..<6 {
    assert_eq(status_of(drive(app)), 503)
  }
  assert_eq(ran.val, 6)
  // the seventh is shed: same 503, but the app never sees it
  assert_eq(status_of(drive(app)), 503)
  assert_eq(ran.val, 6)
}
