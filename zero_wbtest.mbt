///|
/// Build a synthetic request for routing assertions.
fn mkreq(m : String, path : String) -> @moonasgi.Request {
  { http_method: m, path, query_string: b"", headers: [], body: b"" }
}

///|
/// A scope carrying only the given request headers, for middleware unit tests.
fn scope_with(headers : Array[(String, String)]) -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: "GET",
    scheme: "http",
    path: "/",
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
/// Look up a header value by name in a header list.
fn header_of(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
test "config-driven server assembly + describe" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let conf = ServiceConf::new(name="greet", host="127.0.0.1", port=8888)
  let server = Server::new(conf, app).use_(logging)
  assert_eq(server.describe(), "greet listening on 127.0.0.1:8888")
  let _ = server.to_asgi()
}

///|
test "default config" {
  let conf = ServiceConf::new()
  assert_eq(conf.name, "app")
  assert_eq(conf.host, "0.0.0.0")
  assert_eq(conf.port, 8888)
  assert_eq(conf.timeout_ms, 3000)
  assert_eq(conf.log_level, Info)
}

///|
test "log level naming, parsing, and ordering" {
  assert_eq(LogLevel::Debug.to_string(), "debug")
  assert_eq(LogLevel::Info.to_string(), "info")
  assert_eq(LogLevel::Error.to_string(), "error")
  assert_eq(LogLevel::Severe.to_string(), "severe")
  assert_eq(LogLevel::parse("severe"), Severe)
  assert_eq(LogLevel::parse("debug"), Debug)
  assert_eq(LogLevel::parse("nonsense"), Info)
  assert_eq(LogLevel::Debug < LogLevel::Severe, true)
}

///|
test "join_path normalises prefix and route" {
  assert_eq(join_path("/api/v1", "/users"), "/api/v1/users")
  assert_eq(join_path("/api/v1/", "/users"), "/api/v1/users")
  assert_eq(join_path("/api/v1", "users"), "/api/v1/users")
  assert_eq(join_path("", "/users"), "/users")
  assert_eq(join_path("/api/v1", ""), "/api/v1")
  assert_eq(join_path("", ""), "/")
}

///|
test "group prefixes routes onto the underlying app" {
  let app = @moonapi.App::new()
  let g = Group::new(app, "/api/v1")
  assert_eq(g.prefix(), "/api/v1")
  g.get("/users", _ctx => @moonapi.text(200, "users"))
  g.post("orders", _ctx => @moonapi.text(201, "made"))
  g.delete("/users/:id", ctx => @moonapi.text(200, ctx.param("id").unwrap()))
  // prefixed paths route
  assert_eq(app.handle(mkreq("GET", "/api/v1/users")).status, 200)
  assert_eq(app.handle(mkreq("POST", "/api/v1/orders")).status, 201)
  assert_eq(app.handle(mkreq("DELETE", "/api/v1/users/42")).status, 200)
  // the un-prefixed path does NOT match
  assert_eq(app.handle(mkreq("GET", "/users")).status, 404)
  // right path, wrong method -> 405
  assert_eq(app.handle(mkreq("PUT", "/api/v1/users")).status, 405)
}

///|
test "cors_headers advertises the configured policy" {
  let conf = CorsConf::new(
    allow_origin="https://example.com",
    allow_credentials=true,
  )
  let headers = cors_headers(conf)
  assert_eq(
    header_of(headers, "access-control-allow-origin"),
    Some("https://example.com"),
  )
  assert_eq(
    header_of(headers, "access-control-allow-credentials"),
    Some("true"),
  )
  assert_eq(header_of(headers, "access-control-max-age"), Some("86400"))
  assert_eq(
    header_of(headers, "access-control-allow-methods"),
    Some("GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS"),
  )
}

///|
test "cors_headers omits credentials when disabled" {
  let headers = cors_headers(CorsConf::new())
  assert_eq(header_of(headers, "access-control-allow-credentials"), None)
  assert_eq(header_of(headers, "access-control-allow-origin"), Some("*"))
}

///|
test "cors middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let _ = cors(CorsConf::new())(app.to_asgi())
}

///|
test "request-id resolution mints and reuses" {
  let counter : Ref[Int] = { val: 0 }
  assert_eq(resolve_request_id(None, counter), "req-1")
  assert_eq(resolve_request_id(None, counter), "req-2")
  assert_eq(resolve_request_id(Some("abc-123"), counter), "abc-123")
  // reuse does not advance the counter
  assert_eq(resolve_request_id(None, counter), "req-3")
}

///|
test "request-id reads the inbound header from an HTTP scope" {
  assert_eq(
    scope_header(scope_with([("x-request-id", "trace-9")]), "x-request-id"),
    Some("trace-9"),
  )
  assert_eq(scope_header(scope_with([]), "x-request-id"), None)
  let _ = request_id()(@moonapi.App::new().to_asgi())
}

///|
test "recovery emits a 500 with a body" {
  let events = internal_error_events()
  let mut status = 0
  let mut body_len = 0
  for e in events {
    match e {
      HttpResponseStart(status=s, ..) => status = s
      HttpResponseBody(body~, more_body=_) => body_len = body.length()
      _ => ()
    }
  }
  assert_eq(status, 500)
  assert_eq(body_len > 0, true)
}

///|
test "full middleware onion assembles and describes" {
  let app = @moonapi.App::new()
  let g = Group::new(app, "/api")
  g.get("/health", _ctx => @moonapi.text(200, "ok"))
  assert_eq(app.handle(mkreq("GET", "/api/health")).status, 200)
  let conf = ServiceConf::new(
    name="svc",
    host="127.0.0.1",
    port=9000,
    log_level=Error,
  )
  let server = Server::new(conf, app)
    .use_(cors(CorsConf::new()))
    .use_(request_id())
    .use_(recovery)
    .use_(logging)
  assert_eq(server.describe(), "svc listening on 127.0.0.1:9000")
  let _ = server.to_asgi()
}
