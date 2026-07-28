///|
/// Render bytes as lowercase hex, for comparing digests against published
/// test vectors.
fn hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder::new()
  for i = 0; i < b.length(); i = i + 1 {
    let v = b[i].to_int()
    sb.write_char(digits[v >> 4].unsafe_to_char())
    sb.write_char(digits[v & 0xF].unsafe_to_char())
  }
  sb.to_string()
}

///|
test "sha256 matches NIST FIPS 180-4 vectors" {
  assert_eq(
    hex(sha256(b"")),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    hex(sha256(b"abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  // a two-block message (> 55 bytes) exercises the length-padding boundary
  assert_eq(
    hex(sha256(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
}

///|
test "hmac-sha256 matches RFC 4231 case 2" {
  let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?")
  assert_eq(
    hex(mac),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
}

///|
test "hmac-sha256 with a key longer than the block is hashed first" {
  // RFC 4231 case 6: 131-byte key, "Test Using Larger Than Block-Size Key ..."
  let key = Bytes::make(131, b'\xaa')
  let mac = hmac_sha256(
    key, b"Test Using Larger Than Block-Size Key - Hash Key First",
  )
  assert_eq(
    hex(mac),
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
  )
}

///|
test "constant_time_eq compares content, rejects length mismatch" {
  assert_eq(constant_time_eq(b"abcdef", b"abcdef"), true)
  assert_eq(constant_time_eq(b"abcdef", b"abcdeg"), false)
  assert_eq(constant_time_eq(b"abc", b"abcd"), false)
  assert_eq(constant_time_eq(b"", b""), true)
}

///|
test "base64url is url-safe and round-trips without padding" {
  let orig = b"\x01\x02\x03\x04\x05"
  assert_eq(base64url_decode(base64url_encode(orig)), orig)
  // a value whose standard base64 contains + and / must come out - and _
  let e = base64url_encode(b"\xfb\xff\xbf")
  assert_eq(e.contains("+"), false)
  assert_eq(e.contains("/"), false)
  assert_eq(e.contains("="), false)
  assert_eq(e.contains("-") || e.contains("_"), true)
  assert_eq(base64url_decode(e), b"\xfb\xff\xbf")
}
