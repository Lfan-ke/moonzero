///|
/// The canonical jwt.io HS256 example token, produced by an independent
/// implementation (Go/JS), so verifying it proves our HMAC + base64url + parsing
/// are wire-correct against the ecosystem — real interop, not a self-round-trip.
/// header `{"alg":"HS256","typ":"JWT"}`, payload
/// `{"sub":"1234567890","name":"John Doe","iat":1516239022}`, secret
/// `your-256-bit-secret`.
let jwtio_token : String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

///|
let jwtio_secret : String = "your-256-bit-secret"

///|
test "jwt_verify accepts an independently-produced HS256 token (interop)" {
  let claims = jwt_verify(jwtio_token, jwtio_secret, 1516239100L)
  assert_eq(claims.get("sub"), Some(Json::string("1234567890")))
  assert_eq(claims.get("name"), Some(Json::string("John Doe")))
  assert_eq(claims.get("iat"), Some(Json::number(1516239022.0)))
}

///|
test "jwt sign -> verify round-trip" {
  let claims : Map[String, Json] = Map([
    ("sub", Json::string("alice")),
    ("role", Json::string("admin")),
    ("exp", Json::number(2000000000.0)),
  ])
  let token = jwt_sign(claims, "topsecret")
  // three segments
  assert_eq(split_char(token, '.').length(), 3)
  let out = jwt_verify(token, "topsecret", 1000000000L)
  assert_eq(out.get("sub"), Some(Json::string("alice")))
  assert_eq(out.get("role"), Some(Json::string("admin")))
}

///|
/// MUTATION-VERIFY target: a token whose signature byte is flipped must be
/// rejected with `BadSignature`. If `jwt_verify`'s HMAC comparison were removed,
/// this assertion goes red.
test "jwt_verify rejects a tampered signature" {
  let token = jwt_sign(Map([("sub", Json::string("bob"))]), "topsecret")
  let parts = split_char(token, '.')
  // flip the last character of the signature segment
  let sig = parts[2]
  let last = sig[sig.length() - 1].unsafe_to_char()
  let flipped = if last == 'A' { 'B' } else { 'A' }
  let tampered = parts[0] +
    "." +
    parts[1] +
    "." +
    sig[0:sig.length() - 1].to_owned() +
    flipped.to_string()
  let mut rejected = false
  try {
    let _ = jwt_verify(tampered, "topsecret", 1000000000L)
  } catch {
    BadSignature => rejected = true
    _ => rejected = false
  }
  assert_eq(rejected, true)
}

///|
test "jwt_verify rejects a token signed with the wrong secret" {
  let token = jwt_sign(Map([("sub", Json::string("carol"))]), "right-secret")
  let mut rejected = false
  try {
    let _ = jwt_verify(token, "wrong-secret", 1000000000L)
  } catch {
    BadSignature => rejected = true
    _ => rejected = false
  }
  assert_eq(rejected, true)
}

///|
test "jwt_verify enforces exp and nbf" {
  // expired: exp is before now
  let expired = jwt_sign(Map([("exp", Json::number(1000.0))]), "s")
  try {
    let _ = jwt_verify(expired, "s", 2000L)
    fail("expected Expired")
  } catch {
    Expired => ()
    e => fail("expected Expired, got " + e.to_string())
  }
  // not yet valid: nbf is after now
  let future = jwt_sign(Map([("nbf", Json::number(5000.0))]), "s")
  try {
    let _ = jwt_verify(future, "s", 2000L)
    fail("expected NotYetValid")
  } catch {
    NotYetValid => ()
    e => fail("expected NotYetValid, got " + e.to_string())
  }
  // valid window: nbf <= now < exp
  let ok = jwt_sign(
    Map([("nbf", Json::number(1000.0)), ("exp", Json::number(9000.0))]),
    "s",
  )
  let claims = jwt_verify(ok, "s", 3000L)
  assert_eq(claims.get("nbf"), Some(Json::number(1000.0)))
}

///|
test "jwt_verify rejects the alg:none downgrade" {
  // forge header {"alg":"none","typ":"JWT"} with an empty signature
  let header = base64url_encode(
    @utf8.encode("{\"alg\":\"none\",\"typ\":\"JWT\"}"),
  )
  let payload = base64url_encode(@utf8.encode("{\"sub\":\"mallory\"}"))
  let forged = header + "." + payload + "."
  let mut rejected = false
  try {
    let _ = jwt_verify(forged, "s", 1000L)
  } catch {
    UnsupportedAlg(_) => rejected = true
    _ => rejected = false
  }
  assert_eq(rejected, true)
}

///|
test "jwt_verify rejects a malformed token" {
  try {
    let _ = jwt_verify("only.two", "s", 1000L)
    fail("expected MalformedToken")
  } catch {
    MalformedToken(_) => ()
    e => fail("expected MalformedToken, got " + e.to_string())
  }
}
