///|
test "strip_bearer extracts the token case-insensitively on the scheme" {
  assert_eq(strip_bearer(Some("Bearer abc.def.ghi")), Some("abc.def.ghi"))
  assert_eq(strip_bearer(Some("bearer abc.def.ghi")), Some("abc.def.ghi"))
  assert_eq(strip_bearer(Some("BEARER xyz")), Some("xyz"))
  assert_eq(strip_bearer(Some("Basic abc")), None)
  assert_eq(strip_bearer(Some("abc")), None)
  assert_eq(strip_bearer(None), None)
}

///|
test "jwt_authorized accepts a valid bearer token and rejects the rest" {
  let token = jwt_sign(
    Map([("sub", Json::string("u1")), ("exp", Json::number(9999.0))]),
    "k",
  )
  assert_eq(jwt_authorized(Some(token), "k", 100L), true)
  // expired
  assert_eq(jwt_authorized(Some(token), "k", 100000L), false)
  // wrong secret
  assert_eq(jwt_authorized(Some(token), "other", 100L), false)
  // absent
  assert_eq(jwt_authorized(None, "k", 100L), false)
  // garbage
  assert_eq(jwt_authorized(Some("not-a-jwt"), "k", 100L), false)
}

///|
test "auth middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/secret", _ctx => @moonapi.text(200, "classified"))
  let clock = ManualClock::new().as_clock()
  let _ = auth("k", clock)(app.to_asgi())
}

///|
test "unauthorized_events carry a 401 and a bearer challenge" {
  let events = unauthorized_events()
  let mut status = 0
  let mut challenge : String? = None
  for e in events {
    match e {
      HttpResponseStart(status=s, headers~, ..) => {
        status = s
        for h in headers {
          if h.0 == "www-authenticate" {
            challenge = Some(h.1)
          }
        }
      }
      _ => ()
    }
  }
  assert_eq(status, 401)
  assert_eq(challenge, Some("Bearer"))
}
