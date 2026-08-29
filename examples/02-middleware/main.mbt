///|
/// Assemble the base middleware onion — CORS, request-id, tracing, structured
/// logging, request logging, and recovery — over a two-route app, then drive a
/// normal request (watching the injected response headers and the JSON access log)
/// and one that raises (watching recovery answer 500 instead of crashing).
///
///     moon run --target native examples/02-middleware
#coverage.skip
async fn main {
  let app = @moonapi.App::new()
  let api = @moonzero.Group::new(app, "/api/v1")
  api.get("/ping", _ctx => @moonapi.text(200, "pong"))
  api.get("/boom", _ctx => raise Boom)

  // An incrementing clock so the access log shows a real elapsed duration.
  let tick : Ref[Int64] = { val: 0L, }
  let clock = @moonzero.Clock::new(() => {
    let now = tick.val
    tick.val = now + 5L
    now
  })
  let conf = @moonzero.ServiceConf::new(
    name="greet",
    host="127.0.0.1",
    port=8888,
  )
  let onion = @moonzero.Server::new(conf, app)
    .use_(@moonzero.cors(@moonzero.CorsConf::new()))
    .use_(@moonzero.request_id())
    .use_(@moonzero.tracing())
    .use_(@moonzero.structured_logging(clock))
    .use_(@moonzero.logging)
    .use_(@moonzero.recovery)
  println(onion.describe())
  let handler = onion.to_asgi()

  // A normal request: 200, with the middleware's response headers stamped on.
  let (status, headers, body) = drive(handler, "GET", "/api/v1/ping", [])
  println("ping -> " + status.to_string() + " body=" + text(body))
  println("  x-request-id=" + hget(headers, "x-request-id"))
  println("  x-trace-id=" + hget(headers, "x-trace-id"))
  println("  traceparent=" + hget(headers, "traceparent"))
  println(
    "  access-control-allow-origin=" +
    hget(headers, "access-control-allow-origin"),
  )

  // A client-supplied request id is reused verbatim rather than minted.
  let (_, reused, _) = drive(handler, "GET", "/api/v1/ping", [
    ("x-request-id", "heke1228"),
  ])
  println("supplied request id reused: " + hget(reused, "x-request-id"))

  // A handler that raises: recovery answers 500 instead of letting it escape.
  let (boom_status, _, boom_body) = drive(handler, "GET", "/api/v1/boom", [])
  println("boom -> " + boom_status.to_string() + " body=" + text(boom_body))

  // The structured access-log record on its own, rendered as one JSON line.
  let entry = @moonzero.RequestLog::{
    http_method: "GET",
    path: "/api/v1/ping",
    status: 200,
    duration_ms: 5L,
    request_id: "req-1",
    client_ip: "127.0.0.1",
    user_agent: "lfanke",
  }
  println("RequestLog: " + entry.render())
}

///|
/// A local error a route raises to exercise recovery.
suberror Boom

///|
/// Feed one request through an assembled ASGI onion in-process, capturing the
/// response status, the `HttpResponseStart` headers, and the body.
async fn drive(
  handler : @moonasgi.AsgiApp,
  verb : String,
  path : String,
  headers : Array[(String, String)],
) -> (Int, Array[(String, String)], Bytes) {
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method=verb, path~, headers~),
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
  let out : Ref[Array[(String, String)]] = { val: [], }
  let body = Buffer()
  let sink : @moonasgi.Send = event => {
    match event {
      HttpResponseStart(status=s, headers=h, ..) => {
        status.val = s
        out.val = h
      }
      HttpResponseBody(body=b, ..) => body.write_bytes(b)
      _ => ()
    }
  }
  handler(scope, receive, sink)
  (status.val, out.val, body.to_bytes())
}

///|
fn hget(headers : Array[(String, String)], name : String) -> String {
  for pair in headers {
    if pair.0 == name {
      return pair.1
    }
  }
  "(none)"
}

///|
fn text(b : Bytes) -> String {
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    sb.write_char(b[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}
