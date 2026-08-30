///|
/// Gate a request through each resilience middleware and watch the status it
/// answers: auth (401 without a Bearer JWT), rate-limit and period-limit (429 once
/// the budget is spent), the breaker (503 while shedding), timeout (503 past the
/// deadline), max-bytes (413 over the limit), and max-conns (admits a request).
///
///     moon run --target native examples/04-resilience-mw
#coverage.skip
async fn main {
  let clk0 = @moonzero.Clock::new(() => 0L)

  // auth: no token is 401, a valid Bearer JWT is 200.
  let secret = "topsecret"
  let claims : Map[String, Json] = Map([
    ("sub", Json::string("lfanke")),
    ("exp", Json::number(999999999.0)),
  ])
  let token = @moonzero.jwt_sign(claims, secret)
  let authclock = @moonzero.Clock::new(() => 1000000L)
  let authed = @moonzero.auth(secret, authclock)(base())
  println("auth no token -> " + drive(authed, []))
  println(
    "auth bearer   -> " + drive(authed, [("authorization", "Bearer " + token)]),
  )

  // rate_limit: a bucket of one admits the first request, refuses the second.
  let bucket = @moonzero.TokenBucket::new(1.0, burst=1.0, now=0)
  let limited = @moonzero.rate_limit(bucket, clk0)(base())
  println("rate_limit first  -> " + drive(limited, []))
  println("rate_limit second -> " + drive(limited, []))

  // period_limit: a fixed window of one, same shape.
  let plim = @moonzero.PeriodLimit::new(period_secs=60, quota=1)
  let windowed = @moonzero.period_limit(plim, clk0)(base())
  println("period_limit first  -> " + drive(windowed, []))
  println("period_limit second -> " + drive(windowed, []))

  // breaker: eight failures past the protection floor, drawn against a roll of
  // 0.0 that loses every time, put the throttle at 503; a healthy one admits.
  let shedding = @moonzero.Breaker::new(clk0, rand=() => 0.0)
  for _ in 0..<8 {
    match shedding.allow() {
      Some(p) => p.reject()
      None => ()
    }
  }
  println(
    "breaker shedding -> " + drive(@moonzero.breaker(shedding)(base()), []),
  )
  println(
    "breaker healthy  -> " +
    drive(@moonzero.breaker(@moonzero.Breaker::new(clk0))(base()), []),
  )

  // timeout: within budget passes, past the deadline answers 503.
  println(
    "timeout within budget -> " +
    drive(@moonzero.timeout(1000L, clk0)(base()), []),
  )
  let ticks : Ref[Int64] = { val: 0L, }
  let jump = @moonzero.Clock::new(() => {
    let v = ticks.val
    ticks.val = v + 1000L
    v
  })
  println(
    "timeout exceeded      -> " +
    drive(@moonzero.timeout(50L, jump)(base()), []),
  )

  // maxbytes: a declared Content-Length over the limit is 413, under it passes.
  let capped = @moonzero.maxbytes(8)(base())
  println("maxbytes over  -> " + drive(capped, [("content-length", "100")]))
  println("maxbytes under -> " + drive(capped, [("content-length", "4")]))

  // max_conns: a permit is free, so the request is admitted and the permit returned.
  let conns = @moonzero.MaxConns::new(2)
  println(
    "max_conns admits -> " + drive(@moonzero.max_conns(conns)(base()), []),
  )
  println("  in_flight after -> " + conns.in_flight().to_string())
}

///|
/// A one-route app that answers 200, wrapped by the middleware under test.
fn base() -> @moonasgi.AsgiApp {
  let app = @moonapi.App::new()
  app.get("/x", _ctx => @moonapi.text(200, "ok"))
  app.to_asgi()
}

///|
/// Feed one GET `/x` through `handler` and return the response status as text.
async fn drive(
  handler : @moonasgi.AsgiApp,
  headers : Array[(String, String)],
) -> String {
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/x", headers~),
  )
  let sent : Ref[Bool] = { val: false, }
  let receive : @moonasgi.Receive = () => {
    if sent.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      sent.val = true
      @moonasgi.Event::HttpRequest(body=b"", more_body=false)
    }
  }
  let status : Ref[Int] = { val: 0, }
  let sink : @moonasgi.Send = event => {
    match event {
      HttpResponseStart(status=s, ..) => status.val = s
      _ => ()
    }
  }
  handler(scope, receive, sink)
  status.val.to_string()
}
