///|
/// A logger writing into `lines` instead of stdout.
fn collecting(
  lines : Array[String],
  level? : LogLevel = Info,
  clock? : Clock,
) -> Logger {
  Logger::new(
    clock.unwrap_or(ManualClock::new(start=233L).as_clock()),
    level~,
    writer=line => lines.push(line),
  )
}

///|
test "a log call below the configured level produces nothing" {
  let lines : Array[String] = []
  let lg = collecting(lines, level=Error)
  lg.debug("emm")
  lg.info("hhh")
  assert_eq(lines.length(), 0)
  lg.error("qwq")
  lg.severe("orz")
  assert_eq(lines.length(), 2)
  assert_eq(json_str(@json.parse(lines[0]), "content"), "qwq")
  assert_eq(json_str(@json.parse(lines[1]), "level"), "severe")
}

///|
test "the threshold moves with set_level, for derived views too" {
  let lines : Array[String] = []
  let lg = collecting(lines)
  let timed = lg.with_duration(23L)
  assert_eq(lg.enabled(Info), true)
  lg.set_level(Severe)
  assert_eq(lg.enabled(Info), false)
  lg.info("hhh")
  timed.info("hhh")
  assert_eq(lines.length(), 0)
  timed.severe("orz")
  assert_eq(lines.length(), 1)
}

///|
test "an entry carries timestamp, level, content, duration and fields" {
  let lines : Array[String] = []
  let lg = collecting(lines)
  lg
  .with_duration(66L)
  .info("GET /ping", fields=[
    LogField::num("status", 200.0),
    LogField::str("request_id", "req-233"),
  ])
  let j = @json.parse(lines[0])
  assert_eq(json_num(j, "@timestamp"), 233.0)
  assert_eq(json_str(j, "level"), "info")
  assert_eq(json_str(j, "content"), "GET /ping")
  assert_eq(json_num(j, "duration"), 66.0)
  assert_eq(json_num(j, "status"), 200.0)
  assert_eq(json_str(j, "request_id"), "req-233")
  // no duration on a plain logger
  lg.info("hhh")
  assert_eq(json_num(@json.parse(lines[1]), "duration"), -1.0)
}

///|
test "an access record turns into the fields that go on the log entry" {
  let entry = RequestLog::{
    http_method: "GET",
    path: "/ping",
    status: 503,
    duration_ms: 12L,
    request_id: "req-7",
    client_ip: "127.0.0.1",
    user_agent: "curl/8",
  }
  let lines : Array[String] = []
  collecting(lines).info("x", fields=entry.fields())
  let j = @json.parse(lines[0])
  assert_eq(json_num(j, "status"), 503.0)
  assert_eq(json_num(j, "duration_ms"), 12.0)
  assert_eq(json_str(j, "client_ip"), "127.0.0.1")
  assert_eq(json_str(j, "user_agent"), "curl/8")
}

///|
test "the process logger takes a level and a writer" {
  let lines : Array[String] = []
  let restore = logx.level()
  defer {
    set_log_level(restore)
    set_log_writer(line => println(line))
  }
  set_log_writer(line => lines.push(line))
  set_log_level(Error)
  logx.info("hhh")
  assert_eq(lines.length(), 0)
  logx.error("qwq")
  assert_eq(lines.length(), 1)
  assert_eq(json_str(@json.parse(lines[0]), "content"), "qwq")
}

///|
test "the system clock reads a real wall time" {
  let now = Clock::system().now()
  // milliseconds since the epoch, so comfortably past 2020
  assert_eq(now > 1_600_000_000_000L, true)
}
