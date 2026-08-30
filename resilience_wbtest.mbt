///|
/// Read a string field out of a rendered JSON log line.
fn json_str(j : Json, key : String) -> String {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// Read a numeric field out of a rendered JSON log line.
fn json_num(j : Json, key : String) -> Double {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => n
        _ => -1.0
      }
    _ => -1.0
  }
}

///|
/// The status carried by an event array's `HttpResponseStart`, or `0`.
fn start_status(events : Array[@moonasgi.Event]) -> Int {
  for e in events {
    match e {
      HttpResponseStart(status~, ..) => return status
      _ => ()
    }
  }
  0
}

///|
test "manual clock advances and drives a Clock view" {
  let mc = ManualClock::new(start=100)
  let ck = mc.as_clock()
  assert_eq(ck.now(), 100L)
  mc.advance(50)
  assert_eq(ck.now(), 150L)
  mc.advance(1000)
  assert_eq(ck.now(), 1150L)
}

///|
test "token bucket allows the burst then blocks, and refills over time" {
  // 1000 tokens/sec == 1 token/ms; burst of 3, full at t=0.
  let b = TokenBucket::new(1000.0, burst=3.0, now=0L)
  assert_eq(b.allow(0L), true) // 3 -> 2
  assert_eq(b.allow(0L), true) // 2 -> 1
  assert_eq(b.allow(0L), true) // 1 -> 0
  assert_eq(b.allow(0L), false) // empty -> blocked
  // 2 ms later, 2 tokens have refilled
  assert_eq(b.available(2L) >= 2.0, true)
  assert_eq(b.allow(2L), true)
  assert_eq(b.allow(2L), true)
  assert_eq(b.allow(2L), false)
  // refill is capped at the burst capacity, never above
  assert_eq(b.available(1_000_000L) <= 3.0, true)
}

///|
test "token bucket: default burst equals the rate" {
  let b = TokenBucket::new(4.0, now=0L)
  assert_eq(b.available(0L), 4.0)
  assert_eq(b.allow_n(4.0, 0L), true)
  assert_eq(b.allow(0L), false)
}

///|
test "deadline expiry and remaining budget" {
  let d = Deadline::start(1000L, 0L)
  assert_eq(d.expired(500L), false)
  assert_eq(d.remaining(500L), 500L)
  assert_eq(d.expired(1000L), true)
  assert_eq(d.remaining(1000L), 0L)
  assert_eq(d.remaining(5000L), 0L) // never negative
  // a non-positive budget is a disabled deadline
  let off = Deadline::start(0L, 0L)
  assert_eq(off.expired(999_999L), false)
  assert_eq(off.remaining(10L), -1L)
}

///|
test "maxbytes: content-length parsing and threshold, case-insensitive" {
  assert_eq(parse_uint("2048"), Some(2048))
  assert_eq(parse_uint(""), None)
  assert_eq(parse_uint("12a"), None)
  let big = scope_with([("content-length", "2000")])
  assert_eq(content_length_exceeds(big, 1024), true)
  assert_eq(content_length_exceeds(big, 4096), false)
  let mixed = scope_with([("Content-Length", "10")])
  assert_eq(content_length_exceeds(mixed, 5), true)
  // missing / unparseable length never trips
  assert_eq(content_length_exceeds(scope_with([]), 5), false)
}

///|
test "reject responses carry the right status codes" {
  assert_eq(start_status(too_many_requests_events()), 429)
  assert_eq(start_status(service_unavailable_events()), 503)
  assert_eq(start_status(timeout_events()), 503)
  assert_eq(start_status(payload_too_large_events()), 413)
}

///|
test "structured request log renders stable JSON fields" {
  let entry = RequestLog::{
    http_method: "GET",
    path: "/ping",
    status: 200,
    duration_ms: 5L,
    request_id: "req-7",
    client_ip: "127.0.0.1",
    user_agent: "curl/8",
  }
  let j = @json.parse(entry.render())
  assert_eq(json_str(j, "method"), "GET")
  assert_eq(json_str(j, "path"), "/ping")
  assert_eq(json_num(j, "status"), 200.0)
  assert_eq(json_num(j, "duration_ms"), 5.0)
  assert_eq(json_str(j, "request_id"), "req-7")
  assert_eq(json_str(j, "client_ip"), "127.0.0.1")
  assert_eq(json_str(j, "user_agent"), "curl/8")
}

///|
test "client ip prefers the first X-Forwarded-For hop" {
  let fwd = scope_with([("x-forwarded-for", "1.2.3.4, 5.6.7.8")])
  assert_eq(client_ip_of(fwd), "1.2.3.4")
  // no forwarded header and no transport peer -> "-"
  assert_eq(client_ip_of(scope_with([])), "-")
}

///|
test "resilience middlewares assemble onto an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let mc = ManualClock::new()
  let ck = mc.as_clock()
  let assembled = Server::new(ServiceConf::new(), app)
    .use_(maxbytes(1024))
    .use_(max_conns(MaxConns::new(100)))
    .use_(rate_limit(TokenBucket::new(10.0, now=0L), ck))
    .use_(breaker(Breaker::new(ck)))
    .use_(timeout(2000L, ck))
    .use_(structured_logging(ck))
  let _ = assembled.to_asgi()
}
