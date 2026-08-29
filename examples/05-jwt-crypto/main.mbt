///|
/// Exercise the self-built crypto behind JWT auth — SHA-256, HMAC-SHA256, and the
/// constant-time comparison — then sign and verify a compact HS256 token,
/// including the ways verification is meant to fail: a tampered signature, an
/// expired token, and the `alg: none` downgrade.
///
///     moon run examples/05-jwt-crypto
#coverage.skip
fn main {
  // SHA-256 of "abc" — the FIPS 180-4 vector the primitive is checked against.
  println("sha256(\"abc\") = " + to_hex(@moonzero.sha256(b"abc")))
  println("hmac_sha256 = " + to_hex(@moonzero.hmac_sha256(b"key", b"heke1228")))

  // Constant-time equality: same bytes match, different bytes do not.
  let a = @moonzero.sha256(b"qwe")
  println(
    "constant_time_eq(a,a)=" +
    @moonzero.constant_time_eq(a, a).to_string() +
    " (a,b)=" +
    @moonzero.constant_time_eq(a, @moonzero.sha256(b"qwq")).to_string(),
  )

  // base64url (JWT's segment alphabet) round-trips arbitrary bytes.
  let seg = @moonzero.base64url_encode(b"heke1228")
  let back = @moonzero.base64url_decode(seg)
  println(
    "base64url \"heke1228\" -> " + seg + " -> len " + back.length().to_string(),
  )

  let secret = "topsecret"
  let claims : Map[String, Json] = Map([
    ("sub", Json::string("lfanke")),
    ("exp", Json::number(2000.0)),
  ])
  let token = @moonzero.jwt_sign(claims, secret)
  println("jwt three segments: " + count_dots(token).to_string())

  // A valid token verifies and hands back its claims.
  try {
    let got = @moonzero.jwt_verify(token, secret, 1000L)
    println("verify ok, sub=" + sub_of(got))
  } catch {
    e => println("unexpected verify failure: " + jwt_reason(e))
  }

  // Each rejection path reports its own JwtError.
  println("wrong secret -> " + reject(token, "wrong", 1000L))
  println("expired (t=3000 >= exp=2000) -> " + reject(token, secret, 3000L))
  let none_hdr = @moonzero.base64url_encode(@utf8.encode("{\"alg\":\"none\"}"))
  let none_pl = @moonzero.base64url_encode(
    @utf8.encode("{\"sub\":\"mallory\"}"),
  )
  println(
    "alg:none downgrade -> " +
    reject(none_hdr + "." + none_pl + ".", secret, 1000L),
  )

  // The middleware's accept/reject decision, as a pure predicate.
  println(
    "jwt_authorized(valid) = " +
    @moonzero.jwt_authorized(Some(token), secret, 1000L).to_string(),
  )
  println(
    "jwt_authorized(none)  = " +
    @moonzero.jwt_authorized(None, secret, 1000L).to_string(),
  )
}

///|
/// Verify a token expected to fail, returning the JwtError's name.
fn reject(token : String, secret : String, now : Int64) -> String {
  try {
    let _ = @moonzero.jwt_verify(token, secret, now)
    "unexpectedly accepted"
  } catch {
    e => jwt_reason(e)
  }
}

///|
fn jwt_reason(e : @moonzero.JwtError) -> String {
  match e {
    MalformedToken(m) => "malformed: " + m
    UnsupportedAlg(a) => "unsupported-alg: " + a
    BadSignature => "bad-signature"
    Expired => "expired"
    NotYetValid => "not-yet-valid"
  }
}

///|
fn sub_of(claims : Map[String, Json]) -> String {
  match claims.get("sub") {
    Some(String(s)) => s
    _ => "?"
  }
}

///|
fn count_dots(s : String) -> Int {
  let mut n = 1
  for i = 0; i < s.length(); i = i + 1 {
    if s[i] == '.' {
      n = n + 1
    }
  }
  n
}

///|
fn to_hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    let v = b[i].to_int()
    sb.write_char(digits[(v >> 4) & 0xF].to_int().unsafe_to_char())
    sb.write_char(digits[v & 0xF].to_int().unsafe_to_char())
  }
  sb.to_string()
}
