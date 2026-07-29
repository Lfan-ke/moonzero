///|
/// SplitMix64 (Steele et al.): one round mixes a 64-bit counter into a
/// well-distributed 64-bit value. Trace and span ids are derived from a request
/// counter through this so they look random and collide rarely, while staying
/// deterministic for tests. A production deployment swaps the counter for a
/// CSPRNG at the edge; the id shape is unchanged.
fn splitmix64(x : UInt64) -> UInt64 {
  let mut z = x + 0x9E3779B97F4A7C15UL
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// The 16 lowercase hex digits of a 64-bit value, most-significant nibble first.
fn hex16(v : UInt64) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder::new()
  for i = 15; i >= 0; i = i - 1 {
    let nibble = ((v >> (i * 4)) & 0xFUL).to_int()
    sb.write_char(digits[nibble].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// A 32-hex-char (128-bit) trace id from `seed`, mixing two independent words.
pub fn generate_trace_id(seed : Int64) -> String {
  let s = seed.reinterpret_as_uint64()
  hex16(splitmix64(s * 2UL)) + hex16(splitmix64(s * 2UL + 1UL))
}

///|
/// A 16-hex-char (64-bit) span id from `seed`.
pub fn generate_span_id(seed : Int64) -> String {
  hex16(splitmix64(seed.reinterpret_as_uint64() * 2UL + 2UL))
}

///|
/// A W3C Trace Context (← go-zero's OpenTelemetry propagation): the 128-bit trace
/// id shared across a request's whole call tree, the 64-bit span id of the current
/// hop, and the 8-bit sampling flags.
pub(all) struct TraceContext {
  trace_id : String
  span_id : String
  flags : Int
}

///|
/// Format as a W3C `traceparent` header value:
/// `00-<32 hex trace-id>-<16 hex span-id>-<2 hex flags>`.
pub fn TraceContext::to_traceparent(self : TraceContext) -> String {
  "00-" + self.trace_id + "-" + self.span_id + "-" + two_hex(self.flags)
}

///|
/// The trace id (the value propagated unchanged down the call tree).
pub fn TraceContext::trace_id(self : TraceContext) -> String {
  self.trace_id
}

///|
/// The span id of this hop.
pub fn TraceContext::span_id(self : TraceContext) -> String {
  self.span_id
}

///|
/// A two-hex-digit rendering of a byte (the `traceparent` version/flags fields).
fn two_hex(n : Int) -> String {
  let digits = "0123456789abcdef"
  let hi = digits[(n >> 4) & 0xF].to_int().unsafe_to_char()
  let lo = digits[n & 0xF].to_int().unsafe_to_char()
  let sb = StringBuilder::new()
  sb.write_char(hi)
  sb.write_char(lo)
  sb.to_string()
}

///|
/// Whether `s` is exactly `n` lowercase- or uppercase-hex digits.
fn is_hex(s : String, n : Int) -> Bool {
  if s.length() != n {
    return false
  }
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    let is_digit = c >= 0x30 && c <= 0x39
    let is_lower = c >= 0x61 && c <= 0x66
    let is_upper = c >= 0x41 && c <= 0x46
    if !(is_digit || is_lower || is_upper) {
      return false
    }
  }
  true
}

///|
/// Parse a W3C `traceparent` value, or `None` if it is malformed. Only the four
/// canonical fields with correct lengths are accepted; the flags default to `0`
/// if unparseable.
pub fn parse_traceparent(value : String) -> TraceContext? {
  let parts = split_char(value, '-')
  if parts.length() != 4 {
    return None
  }
  if !(is_hex(parts[0], 2) && is_hex(parts[1], 32) && is_hex(parts[2], 16)) {
    return None
  }
  if !is_hex(parts[3], 2) {
    return None
  }
  Some({ trace_id: parts[1], span_id: parts[2], flags: hex_byte(parts[3]) })
}

///|
/// Parse a two-hex-digit string as a byte (`0` on a bad digit).
fn hex_byte(s : String) -> Int {
  if s.length() != 2 {
    return 0
  }
  (hex_digit(s[0].to_int()) << 4) | hex_digit(s[1].to_int())
}

///|
/// A single hex digit's value (`0` on a non-hex code unit).
fn hex_digit(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else {
    0
  }
}

///|
/// Derive the outgoing trace context for a request: reuse the inbound
/// `traceparent`'s trace id if the client sent a valid one (continuing the
/// distributed trace), else start a new trace, and always mint a fresh child span
/// id from `seed`. This is the propagation decision, pulled out as a pure function
/// so it is testable without the transport.
pub fn next_trace_context(inbound : String?, seed : Int64) -> TraceContext {
  let span = generate_span_id(seed)
  match inbound {
    Some(v) =>
      match parse_traceparent(v) {
        Some(parent) => { trace_id: parent.trace_id, span_id: span, flags: 1 }
        None => { trace_id: generate_trace_id(seed), span_id: span, flags: 1 }
      }
    None => { trace_id: generate_trace_id(seed), span_id: span, flags: 1 }
  }
}

///|
/// Trace-id propagation middleware (← go-zero's `trace` handler): continue the
/// inbound `traceparent` trace or start a new one, mint a child span, and stamp
/// both `traceparent` and a convenience `x-trace-id` onto the response so the id
/// flows to the client and downstream calls. The per-assembly seed counter keeps
/// span ids distinct across the requests this layer serves. Non-HTTP scopes pass
/// through untraced.
pub fn tracing(header? : String = "x-trace-id") -> Middleware {
  let counter : Ref[Int64] = { val: 0L }
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) => {
          counter.val = counter.val + 1L
          let inbound = scope_header(scope, "traceparent")
          let ctx = next_trace_context(inbound, counter.val)
          let wrapped : @moonasgi.Send = event => {
            match event {
              HttpResponseStart(status~, headers~, trailers~) =>
                send(
                  @moonasgi.Event::HttpResponseStart(
                    status~,
                    headers=[
                      (header, ctx.trace_id),
                      ("traceparent", ctx.to_traceparent()),
                      ..headers,
                    ],
                    trailers~,
                  ),
                )
              other => send(other)
            }
          }
          inner(scope, receive, wrapped)
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
