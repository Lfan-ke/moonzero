///|
test "counter vector accrues per label and totals across labels" {
  let c = CounterVec::new()
  // an unseen label reads zero
  assert_eq(c.value("GET /ping 200"), 0L)
  c.inc("GET /ping 200")
  c.inc("GET /ping 200")
  c.add("POST /users 201", 3L)
  assert_eq(c.value("GET /ping 200"), 2L)
  assert_eq(c.value("POST /users 201"), 3L)
  assert_eq(c.total(), 5L)
  assert_eq(c.labels().length(), 2)
}

///|
test "histogram buckets are cumulative with sum and count" {
  let h = Histogram::new(bounds=[10, 100, 1000])
  h.observe(5.0) // <= 10, 100, 1000
  h.observe(50.0) // <= 100, 1000
  h.observe(5000.0) // above every bound: only +Inf (count)
  assert_eq(h.bucket_count(0), 1L) // le 10
  assert_eq(h.bucket_count(1), 2L) // le 100
  assert_eq(h.bucket_count(2), 2L) // le 1000
  assert_eq(h.total(), 3L)
  assert_eq(h.sum_value(), 5055.0)
  assert_eq(h.mean(), 1685.0)
  assert_eq(h.bounds().length(), 3)
}

///|
test "histogram boundary value lands in its own bucket" {
  let h = Histogram::new(bounds=[10, 100])
  h.observe(10.0) // exactly the bound -> counted (le is inclusive)
  h.observe(100.0)
  assert_eq(h.bucket_count(0), 1L) // only the 10.0 observation is <= 10
  assert_eq(h.bucket_count(1), 2L) // both are <= 100
  assert_eq(h.total(), 2L)
}

///|
test "empty histogram has zero mean and default latency buckets" {
  let h = Histogram::new()
  assert_eq(h.total(), 0L)
  assert_eq(h.mean(), 0.0)
  assert_eq(h.sum_value(), 0.0)
  // the go-zero default latency ladder
  assert_eq(h.bounds().length(), default_latency_buckets.length())
  assert_eq(h.bounds()[0], 1.0)
  assert_eq(h.bounds()[default_latency_buckets.length() - 1], 5000.0)
}

///|
test "server metrics expose the request counter and latency histogram" {
  let m = ServerMetrics::new()
  m.requests().inc("GET /ping 200")
  m.latency().observe(12.0)
  assert_eq(m.requests().value("GET /ping 200"), 1L)
  assert_eq(m.latency().total(), 1L)
  assert_eq(m.latency().sum_value(), 12.0)
}

///|
test "metrics middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let clock = ManualClock::new().as_clock()
  let _ = metrics(ServerMetrics::new(), clock)(app.to_asgi())
}
