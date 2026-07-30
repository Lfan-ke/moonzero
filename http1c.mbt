// A minimal HTTP/1 client codec — the wire the consul-backed discovery driver speaks
// to a consul agent. A request is built as an HTTP/1.0 message with `Connection: close`
// (so the response is delimited by the server closing the socket — no chunked framing
// to unpick), and a response is parsed into its status code, headers, and body. Pure
// bytes-in/bytes-out, so it runs and is tested on every backend; the socket that
// carries these bytes to a real consul lives in the native `discov` driver.

///|
/// A malformed HTTP response.
pub suberror Http1Error {
  Http1Error(String)
}

///|
/// A parsed HTTP response: the status code, the headers as `(name, value)` pairs with
/// names lower-cased, and the raw body bytes.
pub struct Http1Response {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// The status code.
pub fn Http1Response::status(self : Http1Response) -> Int {
  self.status
}

///|
/// The raw body bytes.
pub fn Http1Response::body(self : Http1Response) -> Bytes {
  self.body
}

///|
/// The first value of header `name` (matched case-insensitively), or `None`.
pub fn Http1Response::header(self : Http1Response, name : String) -> String? {
  let want = name.to_lower()
  for pair in self.headers {
    if pair.0 == want {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Build an HTTP/1.0 request: request line, `Host`, an optional `Content-Type`, a
/// `Content-Length` for the body, and `Connection: close`, then the body. Sending 1.0
/// with `close` makes the response close-delimited, so the client reads to EOF.
pub fn http1_request(
  verb : String,
  path : String,
  host : String,
  body : Bytes,
  content_type? : String = "",
) -> Bytes {
  let buf = Buffer()
  http1_write_str(buf, verb + " " + path + " HTTP/1.0\r\n")
  http1_write_str(buf, "Host: " + host + "\r\n")
  if content_type != "" {
    http1_write_str(buf, "Content-Type: " + content_type + "\r\n")
  }
  http1_write_str(buf, "Content-Length: " + body.length().to_string() + "\r\n")
  http1_write_str(buf, "Connection: close\r\n\r\n")
  buf.write_bytes(body)
  buf.to_bytes()
}

///|
/// Parse a whole HTTP response (status line, headers, body). The body is everything
/// after the header terminator, trimmed to `Content-Length` when the server sent one.
pub fn http1_parse_response(data : Bytes) -> Http1Response raise Http1Error {
  let sep = http1_find_header_end(data)
  guard sep >= 0 else { raise Http1Error("no header terminator (CRLF CRLF)") }
  let head = @utf8.decode_lossy(data[0:sep])
  let lines = http1_split_crlf(head)
  guard lines.length() >= 1 else { raise Http1Error("empty response head") }
  let status = http1_parse_status(lines[0])
  let headers : Array[(String, String)] = []
  for i = 1; i < lines.length(); i = i + 1 {
    let line = lines[i]
    match http1_split_header(line) {
      Some(pair) => headers.push(pair)
      None => ()
    }
  }
  let body_start = sep + 4
  let mut body = if body_start <= data.length() {
    data[body_start:data.length()].to_owned()
  } else {
    b""
  }
  // Honour an explicit Content-Length if the server sent one and more bytes trailed.
  for pair in headers {
    if pair.0 == "content-length" {
      match http1_parse_int(pair.1) {
        Some(n) =>
          if n >= 0 && n <= body.length() {
            body = body[0:n].to_owned()
          }
        None => ()
      }
    }
  }
  { status, headers, body }
}

///|
/// The index of the `\r\n\r\n` that ends the header block, or `-1`.
fn http1_find_header_end(data : Bytes) -> Int {
  for i = 0; i + 3 < data.length(); i = i + 1 {
    if data[i] == b'\r' &&
      data[i + 1] == b'\n' &&
      data[i + 2] == b'\r' &&
      data[i + 3] == b'\n' {
      return i
    }
  }
  -1
}

///|
/// Split a header block on CRLF into its lines (empty lines dropped).
fn http1_split_crlf(head : String) -> Array[String] {
  let out : Array[String] = []
  let line = Buffer()
  let mut i = 0
  while i < head.length() {
    let c = head[i]
    if c == '\r' && i + 1 < head.length() && head[i + 1] == '\n' {
      let s = @utf8.decode_lossy(line.to_bytes()[:])
      if s != "" {
        out.push(s)
      }
      line.reset()
      i += 2
    } else {
      // ASCII header text; keep the low byte.
      line.write_byte((c.to_int() & 0xFF).to_byte())
      i += 1
    }
  }
  let s = @utf8.decode_lossy(line.to_bytes()[:])
  if s != "" {
    out.push(s)
  }
  out
}

///|
/// Parse the status code out of a status line like `HTTP/1.1 200 OK`.
fn http1_parse_status(line : String) -> Int raise Http1Error {
  let mut i = 0
  // Skip the HTTP version token.
  while i < line.length() && line[i] != ' ' {
    i += 1
  }
  while i < line.length() && line[i] == ' ' {
    i += 1
  }
  let start = i
  while i < line.length() && line[i] != ' ' {
    i += 1
  }
  match http1_parse_int(line[start:i].to_owned()) {
    Some(n) => n
    None => raise Http1Error("no status code in: " + line)
  }
}

///|
/// Split a header line `Name: Value` into a lower-cased name and its value (leading
/// space trimmed), or `None` if it has no colon.
fn http1_split_header(line : String) -> (String, String)? {
  let mut colon = -1
  for i = 0; i < line.length(); i = i + 1 {
    if line[i] == ':' {
      colon = i
      break
    }
  }
  guard colon > 0 else { return None }
  let name = line[0:colon].to_owned().to_lower()
  let mut vstart = colon + 1
  while vstart < line.length() && line[vstart] == ' ' {
    vstart += 1
  }
  Some((name, line[vstart:line.length()].to_owned()))
}

///|
/// Parse a non-negative decimal integer, or `None`.
fn http1_parse_int(s : String) -> Int? {
  if s.length() == 0 {
    return None
  }
  let mut n = 0
  for i = 0; i < s.length(); i = i + 1 {
    let d = s[i].to_int() - 0x30
    if d < 0 || d > 9 {
      return None
    }
    n = n * 10 + d
  }
  Some(n)
}

///|
/// Append the ASCII string `s` to `buf`.
fn http1_write_str(buf : Buffer, s : String) -> Unit {
  buf.write_bytes(@utf8.encode(s))
}
