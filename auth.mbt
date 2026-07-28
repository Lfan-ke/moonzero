///|
/// The `Bearer ` scheme prefix an `Authorization` header carries a JWT under.
let bearer_prefix : String = "Bearer "

///|
/// Extract the raw token from an `Authorization: Bearer <token>` header value,
/// or `None` if the value is absent or not a bearer credential. The scheme name
/// is matched case-insensitively (RFC 7235 makes it case-insensitive), the token
/// verbatim.
fn strip_bearer(value : String?) -> String? {
  match value {
    Some(v) =>
      if v.length() >= bearer_prefix.length() &&
        v[0:bearer_prefix.length()].to_owned().to_lower() ==
        bearer_prefix.to_lower() {
        Some(v[bearer_prefix.length():].to_owned())
      } else {
        None
      }
    None => None
  }
}

///|
/// The event stream an unauthenticated request receives: a `401 Unauthorized`
/// with a `WWW-Authenticate: Bearer` challenge and a short plain-text body. A
/// pure value so the guard's rejection is testable without the async transport.
fn unauthorized_events() -> Array[@moonasgi.Event] {
  [
    @moonasgi.Event::HttpResponseStart(status=401, headers=[
      ("content-type", "text/plain; charset=utf-8"),
      ("www-authenticate", "Bearer"),
    ]),
    @moonasgi.Event::HttpResponseBody(body=b"401 Unauthorized", more_body=false),
  ]
}

///|
/// Whether a request bearing `token` is authorised at `now_secs`: the token
/// verifies against `secret` under HS256 and is neither expired nor
/// not-yet-valid. A missing token is unauthorised. Exposed as a pure decision so
/// the middleware's accept/reject is testable without driving the transport.
pub fn jwt_authorized(
  token : String?,
  secret : String,
  now_secs : Int64,
) -> Bool {
  match token {
    Some(t) =>
      try {
        let _ = jwt_verify(t, secret, now_secs)
        true
      } catch {
        _ => false
      }
    None => false
  }
}

///|
/// JWT auth middleware (← go-zero's `handler.Authorize`): require every HTTP
/// request to carry a valid `Authorization: Bearer <jwt>` header. The token is
/// verified against `secret` under HS256 at the current time read from `clock`
/// (milliseconds, converted to the JWT seconds epoch); an absent, malformed,
/// tampered, expired, or not-yet-valid token is rejected with `401 Unauthorized`
/// before the wrapped app runs. Non-HTTP scopes (lifespan, websocket) pass
/// through untouched.
pub fn auth(secret : String, clock : Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) => {
          let token = strip_bearer(scope_header(scope, "authorization"))
          let now_secs = clock.now() / 1000L
          if jwt_authorized(token, secret, now_secs) {
            inner(scope, receive, send)
          } else {
            for event in unauthorized_events() {
              send(event)
            }
          }
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
