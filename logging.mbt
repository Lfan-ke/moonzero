///|
/// A structured access-log record (← go-zero's `logx` HTTP access fields). Rather
/// than a free-form line, each request is captured as typed fields and rendered
/// as one JSON object per line — the format go-zero emits under `logx` and the
/// shape log collectors (ELK, Loki) expect.
pub(all) struct RequestLog {
  http_method : String
  path : String
  status : Int
  duration_ms : Int64
  request_id : String
  client_ip : String
  user_agent : String
}

///|
/// The record as a JSON value with a stable field order, `duration_ms` rendered
/// as a number of milliseconds.
pub fn RequestLog::to_json(self : RequestLog) -> Json {
  Json::object(
    Map([
      ("method", Json::string(self.http_method)),
      ("path", Json::string(self.path)),
      ("status", Json::number(self.status.to_double())),
      ("duration_ms", Json::number(self.duration_ms.to_double())),
      ("request_id", Json::string(self.request_id)),
      ("client_ip", Json::string(self.client_ip)),
      ("user_agent", Json::string(self.user_agent)),
    ]),
  )
}

///|
/// The record rendered as a single-line JSON string, ready to write to a log
/// sink.
pub fn RequestLog::render(self : RequestLog) -> String {
  self.to_json().stringify()
}

///|
/// The client IP from an HTTP scope: the `X-Forwarded-For` first hop if present
/// (proxy-aware, as go-zero's `httpx.GetRemoteAddr`), else the transport peer
/// from the scope's `client`, else `"-"`.
fn client_ip_of(scope : @moonasgi.Scope) -> String {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0.to_lower() == "x-forwarded-for" {
          let raw = pair.1
          let mut end = 0
          while end < raw.length() && raw[end] != ',' {
            end = end + 1
          }
          return raw[0:end].to_owned()
        }
      }
      match hs.client {
        Some((ip, _)) => ip
        None => "-"
      }
    }
    _ => "-"
  }
}

///|
/// A request header's value from an HTTP scope, matched case-insensitively;
/// `default` when absent or on a non-HTTP scope.
fn header_ci(
  scope : @moonasgi.Scope,
  name : String,
  default : String,
) -> String {
  match scope {
    Http(hs) => {
      for pair in hs.headers {
        if pair.0.to_lower() == name {
          return pair.1
        }
      }
      default
    }
    _ => default
  }
}

///|
/// Structured-logging middleware (← go-zero's `LogHandler`): time each HTTP
/// request on the shared clock, capture its method/path/client-ip/user-agent and
/// the response status observed on `HttpResponseStart`, and print one
/// `RequestLog` JSON line when the response starts. Non-HTTP scopes pass through
/// without logging.
pub fn structured_logging(clock : Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(hs) => {
          let start = clock.now()
          let verb = hs.http_method
          let path = hs.path
          let ip = client_ip_of(scope)
          let ua = header_ci(scope, "user-agent", "-")
          let rid = header_ci(scope, "x-request-id", "-")
          let logged : Ref[Bool] = { val: false }
          let observed : @moonasgi.Send = event => {
            match event {
              HttpResponseStart(status~, headers~) => {
                if !logged.val {
                  logged.val = true
                  let entry = RequestLog::{
                    http_method: verb,
                    path,
                    status,
                    duration_ms: clock.now() - start,
                    request_id: rid,
                    client_ip: ip,
                    user_agent: ua,
                  }
                  println(entry.render())
                }
                send(@moonasgi.Event::HttpResponseStart(status~, headers~))
              }
              other => send(other)
            }
          }
          inner(scope, receive, observed)
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
