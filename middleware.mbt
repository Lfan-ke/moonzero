///|
/// The event stream recovery emits in place of a failed request: a `500` start
/// followed by a short plain-text body. Kept as a pure value so the guard's
/// behaviour is testable without driving the async transport.
fn internal_error_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(
      status=500,
      headers=[("content-type", "text/plain; charset=utf-8")],
      trailers=false,
    ),
    @moonasgi.Event::HttpResponseBody(
      body=b"Internal Server Error",
      more_body=false,
    ),
  ]
}

///|
/// Recovery middleware (← go-zero's `RecoverHandler`): run the wrapped
/// application inside a `try`, and if it raises, emit a `500 Internal Server
/// Error` instead of letting the failure escape to the server. A downstream that
/// has already streamed its response start before raising will produce a second
/// start event; recovery is a last-resort guard, so it always answers rather than
/// trying to detect that race.
pub fn recovery(inner : @moonasgi.AsgiApp) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    inner(scope, receive, send) catch {
      _ =>
        for event in internal_error_events() {
          send(event)
        }
    }
  }
}

///|
/// CORS configuration (← go-zero's `cors.Middleware` options): the values echoed
/// back in the `Access-Control-*` preflight/response headers.
pub(all) struct CorsConf {
  allow_origin : String
  allow_methods : String
  allow_headers : String
  allow_credentials : Bool
  max_age : Int
}

///|
/// Build a permissive CORS config: any origin, the full method set, and a one-day
/// preflight cache. Credentials are off by default, matching go-zero.
pub fn CorsConf::new(
  allow_origin? : String = "*",
  allow_methods? : String = "GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS",
  allow_headers? : String = "Content-Type, Authorization",
  allow_credentials? : Bool = false,
  max_age? : Int = 86400,
) -> CorsConf {
  { allow_origin, allow_methods, allow_headers, allow_credentials, max_age, }
}

///|
/// The `Access-Control-*` header pairs a config contributes. Credentials are only
/// advertised when enabled, matching go-zero's conditional emission.
fn cors_headers(conf : CorsConf) -> Array[(String, String)] {
  let out : Array[(String, String)] = [
    ("access-control-allow-origin", conf.allow_origin),
    ("access-control-allow-methods", conf.allow_methods),
    ("access-control-allow-headers", conf.allow_headers),
    ("access-control-max-age", conf.max_age.to_string()),
  ]
  if conf.allow_credentials {
    out.push(("access-control-allow-credentials", "true"))
  }
  out
}

///|
/// CORS middleware (← go-zero's `cors.Middleware`): wrap the outbound `Send` so
/// the configured `Access-Control-*` headers are injected onto every
/// `HttpResponseStart`, leaving the body and other events untouched.
pub fn cors(conf : CorsConf) -> Middleware {
  inner => {
    (scope, receive, send) => {
      let wrapped : @moonasgi.Send = event => {
        match event {
          HttpResponseStart(status~, headers~, trailers~) =>
            send(
              @moonasgi.Event::HttpResponseStart(
                status~,
                headers=[..cors_headers(conf), ..headers],
                trailers~,
              ),
            )
          other => send(other)
        }
      }
      inner(scope, receive, wrapped)
    }
  }
}

///|
/// Read a header from an HTTP scope (lowercased-name convention); `None` for
/// non-HTTP scopes or a missing header.
fn scope_header(scope : @moonasgi.Scope, name : String) -> String? {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0 == name {
          return Some(pair.1)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Resolve the id for a request: reuse an inbound one verbatim, otherwise mint the
/// next monotonic `req-N` from the shared counter.
fn resolve_request_id(inbound : String?, counter : Ref[Int]) -> String {
  match inbound {
    Some(existing) => existing
    None => {
      counter.val = counter.val + 1
      "req-" + counter.val.to_string()
    }
  }
}

///|
/// Request-ID middleware (← go-zero's trace/`x-request-id` handling): reuse an
/// inbound `x-request-id` if the client sent one, otherwise mint a fresh
/// monotonic id, and stamp it onto every response's `HttpResponseStart`. The
/// counter is captured once per assembly, so ids stay unique across the requests
/// this layer serves.
pub fn request_id(header? : String = "x-request-id") -> Middleware {
  let counter : Ref[Int] = { val: 0, }
  inner => {
    (scope, receive, send) => {
      let id = resolve_request_id(scope_header(scope, header), counter)
      let wrapped : @moonasgi.Send = event => {
        match event {
          HttpResponseStart(status~, headers~, trailers~) =>
            send(
              @moonasgi.Event::HttpResponseStart(
                status~,
                headers=[(header, id), ..headers],
                trailers~,
              ),
            )
          other => send(other)
        }
      }
      inner(scope, receive, wrapped)
    }
  }
}
