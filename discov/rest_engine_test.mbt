///|
/// A GET scope at `path` carrying `headers`.
fn scope_at(
  path : String,
  headers : Array[(String, String)],
) -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: "GET",
    scheme: "http",
    path,
    raw_path: b"/",
    query_string: b"",
    root_path: "",
    headers,
    client: None,
    server: None,
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
}

///|
/// Drive one request through `app` and collect what it sent.
async fn run(
  app : @moonasgi.AsgiApp,
  scope : @moonasgi.Scope,
) -> Array[@moonasgi.Event] {
  let sent : Array[@moonasgi.Event] = []
  app(scope, fn() { @moonasgi.Event::HttpDisconnect }, fn(e) { sent.push(e) })
  sent
}

///|
/// The response header `name`, or `"-"`.
fn header_of(events : Array[@moonasgi.Event], name : String) -> String {
  for e in events {
    match e {
      HttpResponseStart(headers~, ..) =>
        for pair in headers {
          if pair.0 == name {
            return pair.1
          }
        }
      _ => ()
    }
  }
  "-"
}

///|
/// A one-route app under the chain `conf` asks for, logging into `lines`.
fn assemble(
  conf : @moonzero.RestConf,
  lines : Array[String],
) -> @moonasgi.AsgiApp raise @moonzero.ConfigError {
  let clock = @moonzero.ManualClock::new().as_clock()
  let logger = @moonzero.Logger::new(clock, writer=line => lines.push(line))
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  app.get("/healthz", _ctx => @moonapi.text(200, "ok"))
  @moonzero.RestEngine::new(conf, clock~, logger~).build(app).to_asgi()
}

///|
/// The `Middlewares` flags decide what the assembled app actually does, not just
/// what `names()` reports.
async test "the body cap is enforced only while its flag is on" {
  let big = scope_at("/ping", [("content-length", "100")])
  let on = assemble(
    @moonzero.RestConf::from_yaml("Name: api\nPort: 8888\nMaxBytes: 8\n"),
    [],
  )
  assert_eq(status_of(run(on, big)), 413)
  let off = assemble(
    @moonzero.RestConf::from_yaml(
      (
        #|Name: api
        #|Port: 8888
        #|MaxBytes: 8
        #|Middlewares:
        #|  MaxBytes: false
      ),
    ),
    [],
  )
  assert_eq(status_of(run(off, big)), 200)
}

///|
/// go-zero puts the log handler outside the body cap, so a request refused by the
/// cap is still logged. Fold the chain the other way round and this line vanishes.
async test "the access log sits outside the body cap" {
  let lines : Array[String] = []
  let app = assemble(
    @moonzero.RestConf::from_yaml("Name: api\nPort: 8888\nMaxBytes: 8\n"),
    lines,
  )
  let _ = run(app, scope_at("/ping", [("content-length", "100")]))
  assert_eq(lines.length(), 1)
  assert_eq(lines[0].contains("413"), true)
}

///|
/// The configured level reaches the access log: at `error` a served request logs
/// nothing at all.
async test "the access log is silent below the configured level" {
  let quiet : Array[String] = []
  let app = assemble(
    @moonzero.RestConf::from_yaml(
      (
        #|Name: api
        #|Port: 8888
        #|Log:
        #|  Level: error
      ),
    ),
    quiet,
  )
  assert_eq(status_of(run(app, scope_at("/ping", []))), 200)
  assert_eq(quiet.length(), 0)
  let loud : Array[String] = []
  let noisy = assemble(
    @moonzero.RestConf::from_yaml("Name: api\nPort: 8888\n"),
    loud,
  )
  assert_eq(status_of(run(noisy, scope_at("/ping", []))), 200)
  assert_eq(loud.length(), 1)
  assert_eq(loud[0].contains("GET /ping"), true)
}

///|
async test "a path in TraceIgnorePaths is not traced" {
  let app = assemble(
    @moonzero.RestConf::from_yaml(
      (
        #|Name: api
        #|Port: 8888
        #|TraceIgnorePaths:
        #|  - /healthz
      ),
    ),
    [],
  )
  assert_eq(
    header_of(run(app, scope_at("/ping", [])), "x-trace-id") != "-",
    true,
  )
  assert_eq(header_of(run(app, scope_at("/healthz", [])), "x-trace-id"), "-")
}

///|
async test "the prometheus layer records into the engine's own metric set" {
  let clock = @moonzero.ManualClock::new().as_clock()
  let engine = @moonzero.RestEngine::new(
    @moonzero.RestConf::from_yaml("Name: api\nPort: 8888\n"),
    clock~,
    logger=@moonzero.Logger::new(clock, writer=_ => ()),
  )
  assert_eq(engine.conf().port(), 8888)
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let asgi = engine.build(app).to_asgi()
  assert_eq(engine.metrics().requests().total(), 0L)
  let _ = run(asgi, scope_at("/ping", []))
  assert_eq(engine.metrics().requests().total(), 1L)
  assert_eq(engine.metrics().requests().value("GET /ping 200"), 1L)
}

///|
async test "shedding refuses without running the app" {
  let usage : Ref[Int64] = { val: 0L, }
  let s = @moonzero.Shedder::new(900L, usage=() => usage.val)
  let ran : Ref[Int] = { val: 0, }
  let app = @moonzero.shedding(s)((_s, _r, snd) => {
    ran.val = ran.val + 1
    snd(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
  })
  assert_eq(status_of(run(app, scope_at("/ping", []))), 200)
  assert_eq(ran.val, 1)
  usage.val = 950L
  assert_eq(status_of(run(app, scope_at("/ping", []))), 503)
  assert_eq(ran.val, 1)
}

///|
async test "the plain logging layer writes through the process logger" {
  let lines : Array[String] = []
  let restore = @moonzero.logx.level()
  defer {
    @moonzero.set_log_level(restore)
    @moonzero.set_log_writer(line => println(line))
  }
  @moonzero.set_log_writer(line => lines.push(line))
  let app = @moonzero.logging(responder(200))
  let _ = run(app, scope_at("/ping", []))
  assert_eq(lines.length(), 1)
  assert_eq(lines[0].contains("GET /ping"), true)
  @moonzero.set_log_level(Severe)
  let _ = run(app, scope_at("/ping", []))
  assert_eq(lines.length(), 1)
}
