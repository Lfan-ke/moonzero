///|
/// The 64 SHA-256 round constants (§4.2.2 of FIPS 180-4): the first 32 bits of
/// the fractional parts of the cube roots of the first 64 primes.
let sha256_k : Array[UInt] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
  0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
  0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
  0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
  0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]

///|
/// A 32-bit right-rotation, the diffusion operator SHA-256 is built from.
fn rotr32(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// SHA-256 (FIPS 180-4): hash an arbitrary byte string to a 32-byte digest. A
/// self-built primitive — MoonBit's core ships no `crypto` — implementing the
/// full message schedule and 64-round compression over 512-bit blocks with the
/// standard length-padding. Verified against the NIST vectors (`""`, `"abc"`).
/// The building block for `hmac_sha256`, and through it for JWT HS256 signing.
pub fn sha256(msg : Bytes) -> Bytes {
  let mut h0 : UInt = 0x6a09e667
  let mut h1 : UInt = 0xbb67ae85
  let mut h2 : UInt = 0x3c6ef372
  let mut h3 : UInt = 0xa54ff53a
  let mut h4 : UInt = 0x510e527f
  let mut h5 : UInt = 0x9b05688c
  let mut h6 : UInt = 0x1f83d9ab
  let mut h7 : UInt = 0x5be0cd19
  let bitlen = (msg.length() * 8).to_uint64()
  let buf = Buffer()
  buf.write_bytes(msg[:])
  buf.write_byte(b'\x80')
  while buf.length() % 64 != 56 {
    buf.write_byte(b'\x00')
  }
  for i = 7; i >= 0; i = i - 1 {
    buf.write_byte(((bitlen >> (i * 8)) & 0xFF).to_byte())
  }
  let data = buf.to_bytes()
  let w : Array[UInt] = Array::make(64, 0U)
  let nblocks = data.length() / 64
  for b = 0; b < nblocks; b = b + 1 {
    let off = b * 64
    for i = 0; i < 16; i = i + 1 {
      let j = off + i * 4
      w[i] = (data[j].to_int().reinterpret_as_uint() << 24) |
        (data[j + 1].to_int().reinterpret_as_uint() << 16) |
        (data[j + 2].to_int().reinterpret_as_uint() << 8) |
        data[j + 3].to_int().reinterpret_as_uint()
    }
    for i = 16; i < 64; i = i + 1 {
      let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
      let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    let mut a = h0
    let mut bb = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    let mut f = h5
    let mut g = h6
    let mut hh = h7
    for i = 0; i < 64; i = i + 1 {
      let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
      let ch = (e & f) ^ (e.lnot() & g)
      let t1 = hh + s1 + ch + sha256_k[i] + w[i]
      let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
      let maj = (a & bb) ^ (a & c) ^ (bb & c)
      let t2 = s0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = bb
      bb = a
      a = t1 + t2
    }
    h0 = h0 + a
    h1 = h1 + bb
    h2 = h2 + c
    h3 = h3 + d
    h4 = h4 + e
    h5 = h5 + f
    h6 = h6 + g
    h7 = h7 + hh
  }
  let out = Buffer()
  for hv in [h0, h1, h2, h3, h4, h5, h6, h7] {
    out.write_byte((hv >> 24).to_byte())
    out.write_byte((hv >> 16).to_byte())
    out.write_byte((hv >> 8).to_byte())
    out.write_byte(hv.to_byte())
  }
  out.to_bytes()
}

///|
/// HMAC-SHA256 (RFC 2104): a keyed message-authentication code over `sha256`.
/// A key longer than the 64-byte block is hashed first; a shorter key is
/// zero-padded. The message is authenticated as
/// `H((K ⊕ opad) ∥ H((K ⊕ ipad) ∥ msg))`. Verified against RFC 4231 test case
/// 2. This is the signature function behind JWT HS256.
pub fn hmac_sha256(key : Bytes, msg : Bytes) -> Bytes {
  let block = 64
  let k0 = Buffer()
  if key.length() > block {
    k0.write_bytes(sha256(key)[:])
  } else {
    k0.write_bytes(key[:])
  }
  while k0.length() < block {
    k0.write_byte(b'\x00')
  }
  let kb = k0.to_bytes()
  let ipad = Buffer()
  let opad = Buffer()
  for i = 0; i < block; i = i + 1 {
    ipad.write_byte((kb[i].to_int() ^ 0x36).to_byte())
    opad.write_byte((kb[i].to_int() ^ 0x5c).to_byte())
  }
  ipad.write_bytes(msg[:])
  let inner = sha256(ipad.to_bytes())
  opad.write_bytes(inner[:])
  sha256(opad.to_bytes())
}

///|
/// A constant-time byte-string equality: it inspects every byte of both inputs
/// regardless of where they first differ, so an attacker cannot recover a valid
/// signature byte-by-byte from response timing. Unequal lengths return `false`
/// immediately (length is not secret). Used to compare JWT signatures.
pub fn constant_time_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut diff = 0
  for i = 0; i < a.length(); i = i + 1 {
    diff = diff | (a[i].to_int() ^ b[i].to_int())
  }
  diff == 0
}
