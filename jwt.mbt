///|
/// base64url encoding (RFC 4648 §5, no padding): standard base64 with `+`/`/`
/// remapped to `-`/`_` and trailing `=` dropped — the alphabet JWT uses for its
/// header, payload, and signature segments.
pub fn base64url_encode(data : Bytes) -> String {
  let std = @base64.encode(data[:], padding=false)
  let sb = StringBuilder()
  for i = 0; i < std.length(); i = i + 1 {
    let c = std[i]
    if c == '+' {
      sb.write_char('-')
    } else if c == '/' {
      sb.write_char('_')
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
  sb.to_string()
}

///|
/// Decode a base64url string (padding optional) back to bytes, remapping
/// `-`/`_` to `+`/`/` before decoding. Lenient about missing padding, the way
/// JWT segments are written.
pub fn base64url_decode(s : String) -> Bytes {
  let sb = StringBuilder()
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == '-' {
      sb.write_char('+')
    } else if c == '_' {
      sb.write_char('/')
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
  @base64.decode_lossy(sb.to_string())
}

///|
/// A JWT verification failure (← go-zero's `handler.Authorize` rejection cases).
/// Every path a bad token can fail on is reported distinctly so callers (and the
/// `auth` middleware) can log or branch precisely.
pub suberror JwtError {
  /// Not three `.`-separated segments, an un-decodable segment, or a payload
  /// that is not a JSON object.
  MalformedToken(String)
  /// The header's `alg` is missing or not `HS256` — including the `alg: "none"`
  /// downgrade attack, which is always rejected.
  UnsupportedAlg(String)
  /// The recomputed HMAC signature does not match the token's signature.
  BadSignature
  /// The `exp` claim is at or before the verification time.
  Expired
  /// The `nbf` (not-before) claim is after the verification time.
  NotYetValid
}

///|
/// Split a string on a single ASCII delimiter into its parts. Core ships no
/// `String::split`, so it is hand-written; used to break a `header.payload.sig`
/// token into three segments.
fn split_char(s : String, delim : Char) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  let d = delim.to_int()
  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == d {
      out.push(sb.to_string())
      sb.reset()
    } else {
      sb.write_char(s[i].unsafe_to_char())
    }
  }
  out.push(sb.to_string())
  out
}

///|
/// The signing input `base64url(header).base64url(payload)` as bytes: the exact
/// octets HMAC-SHA256 runs over, shared by signing and verification.
fn jwt_signing_input(header_seg : String, payload_seg : String) -> Bytes {
  @utf8.encode(header_seg + "." + payload_seg)
}

///|
/// Sign a claims set as a compact JWT using HS256 (← go-zero's
/// `jwt.NewWithClaims(SigningMethodHS256, ...)`). The header is fixed to
/// `{"alg":"HS256","typ":"JWT"}`; `claims` is serialised as the JSON payload
/// (include `exp`/`iat`/`nbf`/`sub`/… as ordinary entries); `secret` is the
/// shared HS256 key. Returns `header.payload.signature`, each segment
/// base64url-encoded.
pub fn jwt_sign(claims : Map[String, Json], secret : String) -> String {
  let header_json =
    #|{"alg":"HS256","typ":"JWT"}
  let header_seg = base64url_encode(@utf8.encode(header_json))
  let payload_seg = base64url_encode(
    @utf8.encode(Json::object(claims).stringify()),
  )
  let sig = hmac_sha256(
    @utf8.encode(secret),
    jwt_signing_input(header_seg, payload_seg),
  )
  header_seg + "." + payload_seg + "." + base64url_encode(sig)
}

///|
/// Read the header segment's `alg`, raising `UnsupportedAlg` for anything but
/// `HS256` — this is where the `alg: "none"` downgrade is refused.
fn check_alg(header_seg : String) -> Unit raise JwtError {
  let text = @utf8.decode_lossy(base64url_decode(header_seg)[:])
  let json = @json.parse(text) catch {
    _ => raise MalformedToken("header is not valid JSON")
  }
  match json {
    Object(m) =>
      match m.get("alg") {
        Some(String("HS256")) => ()
        Some(String(other)) => raise UnsupportedAlg(other)
        _ => raise UnsupportedAlg("missing alg")
      }
    _ => raise MalformedToken("header is not a JSON object")
  }
}

///|
/// Verify a compact HS256 JWT and return its claims (← go-zero's
/// `handler.Authorize`). Checks, in order: three segments; header `alg` is
/// `HS256`; the HMAC-SHA256 signature matches (compared in constant time);
/// `exp` (if present) is strictly after `now_secs`; `nbf` (if present) is at or
/// before `now_secs`. `now_secs` is the verification time as a Unix timestamp in
/// **seconds** (JWT `NumericDate`). Raises the matching `JwtError` on any
/// failure; a tampered payload or signature fails at `BadSignature`.
pub fn jwt_verify(
  token : String,
  secret : String,
  now_secs : Int64,
) -> Map[String, Json] raise JwtError {
  let parts = split_char(token, '.')
  if parts.length() != 3 {
    raise MalformedToken("expected three segments")
  }
  let header_seg = parts[0]
  let payload_seg = parts[1]
  let sig_seg = parts[2]
  check_alg(header_seg)
  let expected = hmac_sha256(
    @utf8.encode(secret),
    jwt_signing_input(header_seg, payload_seg),
  )
  let given = base64url_decode(sig_seg)
  if !constant_time_eq(expected, given) {
    raise BadSignature
  }
  let payload_text = @utf8.decode_lossy(base64url_decode(payload_seg)[:])
  let payload = @json.parse(payload_text) catch {
    _ => raise MalformedToken("payload is not valid JSON")
  }
  let claims = match payload {
    Object(m) => m
    _ => raise MalformedToken("payload is not a JSON object")
  }
  match claims.get("exp") {
    Some(Number(exp, ..)) => if now_secs.to_double() >= exp { raise Expired }
    _ => ()
  }
  match claims.get("nbf") {
    Some(Number(nbf, ..)) => if now_secs.to_double() < nbf { raise NotYetValid }
    _ => ()
  }
  claims
}
