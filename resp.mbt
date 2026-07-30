// RESP — the Redis serialization protocol, the wire a redis client speaks. This is
// the self-built codec the redis-backed discovery driver rides on: a command goes out
// as a RESP array of bulk strings, and every reply shape (RESP2's five types plus
// RESP3's null, boolean, double, big number, bulk error, verbatim string, map, set,
// and push) decodes back into a `RespValue`. The codec is pure bytes-in/bytes-out, so
// it runs and is tested on every backend; the socket client that carries these bytes
// to a real redis lives in the native `discov` driver.

///|
/// A malformed or truncated RESP frame.
pub suberror RespError {
  RespError(String)
}

///|
/// A decoded RESP value. RESP2's null bulk string (`$-1`) and null array (`*-1`) both
/// decode to `Null`, unifying with RESP3's explicit null (`_`). `BulkString` carries
/// raw bytes (redis values are binary-safe); the text-line types carry the decoded
/// string.
pub enum RespValue {
  SimpleString(String)
  Error(String)
  Integer(Int64)
  BulkString(Bytes)
  Null
  Array(Array[RespValue])
  Boolean(Bool)
  Double(Double)
  BigNumber(String)
  BulkError(String)
  VerbatimString(String, Bytes)
  RespMap(Array[(RespValue, RespValue)])
  RespSet(Array[RespValue])
  Push(Array[RespValue])
} derive(Eq, Debug)

///|
/// A short name for a value's RESP type, for error messages ("unexpected `<kind>`
/// reply") — `RespValue` derives `Eq`/`Debug` but not a renderable form.
pub fn resp_kind(value : RespValue) -> String {
  match value {
    SimpleString(_) => "simple-string"
    Error(_) => "error"
    Integer(_) => "integer"
    BulkString(_) => "bulk-string"
    Null => "null"
    Array(_) => "array"
    Boolean(_) => "boolean"
    Double(_) => "double"
    BigNumber(_) => "big-number"
    BulkError(_) => "bulk-error"
    VerbatimString(_, _) => "verbatim-string"
    RespMap(_) => "map"
    RespSet(_) => "set"
    Push(_) => "push"
  }
}

///|
/// Encode a command as the client frame redis expects: an array of bulk strings, one
/// per argument (`*<n>\r\n$<len>\r\n<arg>\r\n`...). Arguments are raw bytes, so binary
/// keys and values round-trip unchanged.
pub fn resp_encode_command(args : Array[Bytes]) -> Bytes {
  let buf = Buffer()
  buf.write_byte(b'*')
  resp_write_int(buf, args.length().to_int64())
  for arg in args {
    buf.write_byte(b'$')
    resp_write_int(buf, arg.length().to_int64())
    buf.write_bytes(arg)
    resp_write_crlf(buf)
  }
  buf.to_bytes()
}

///|
/// Encode a command given string arguments (the common case — command names and keys
/// are text), UTF-8 encoding each.
pub fn resp_command(args : Array[String]) -> Bytes {
  resp_encode_command(args.map(a => @utf8.encode(a)))
}

///|
/// Decode exactly one RESP value from `data`, requiring it to consume the whole input.
/// Trailing bytes after a complete value are a framing error.
pub fn RespValue::decode(data : Bytes) -> RespValue raise RespError {
  let reader = RespReader::new(data)
  let value = reader.read()
  if !reader.at_end() {
    raise RespError("trailing bytes after RESP value")
  }
  value
}

///|
/// A cursor over a RESP byte stream, decoding one value at a time. A socket client
/// feeds it a buffered reply; `read` advances past exactly one value, so several
/// pipelined replies decode in sequence.
pub struct RespReader {
  data : Bytes
  mut pos : Int
}

///|
/// A reader positioned at the start of `data`.
pub fn RespReader::new(data : Bytes) -> RespReader {
  { data, pos: 0 }
}

///|
/// Whether every byte has been consumed.
pub fn RespReader::at_end(self : RespReader) -> Bool {
  self.pos >= self.data.length()
}

///|
/// Decode the next RESP value, advancing the cursor past it.
pub fn RespReader::read(self : RespReader) -> RespValue raise RespError {
  let marker = self.next_byte()
  match marker {
    b'+' => SimpleString(self.read_line_text())
    b'-' => Error(self.read_line_text())
    b':' => Integer(self.read_line_int())
    b',' => resp_parse_double(self.read_line_text())
    b'(' => BigNumber(self.read_line_text())
    b'#' => Boolean(self.read_bool())
    b'_' => {
      self.expect_crlf()
      Null
    }
    b'$' => self.read_bulk(false)
    b'!' => self.read_bulk(true)
    b'=' => self.read_verbatim()
    b'*' => {
      let count = self.read_count()
      if count < 0 {
        Null
      } else {
        Array(self.read_elems(count))
      }
    }
    b'~' => RespSet(self.read_elems(self.read_count()))
    b'>' => Push(self.read_elems(self.read_count()))
    b'%' => RespMap(self.read_map())
    _ => raise RespError("unknown RESP marker 0x" + marker.to_int().to_string())
  }
}

///|
/// The next raw byte, or an error at end of input.
fn RespReader::next_byte(self : RespReader) -> Byte raise RespError {
  if self.pos >= self.data.length() {
    raise RespError("unexpected end of RESP input")
  }
  let b = self.data[self.pos]
  self.pos += 1
  b
}

///|
/// The bytes up to the next CRLF (exclusive), advancing past the CRLF. A line with no
/// terminating CRLF is a framing error.
fn RespReader::read_line(self : RespReader) -> Bytes raise RespError {
  let start = self.pos
  let n = self.data.length()
  for i = start; i < n - 1; i = i + 1 {
    if self.data[i] == b'\r' && self.data[i + 1] == b'\n' {
      let line = self.data[start:i].to_owned()
      self.pos = i + 2
      return line
    }
  }
  raise RespError("RESP line not terminated by CRLF")
}

///|
/// The next line decoded as text.
fn RespReader::read_line_text(self : RespReader) -> String raise RespError {
  @utf8.decode_lossy(self.read_line()[:])
}

///|
/// The next line parsed as a signed integer.
fn RespReader::read_line_int(self : RespReader) -> Int64 raise RespError {
  let text = self.read_line_text()
  @string.parse_int64(text) catch {
    _ => raise RespError("invalid RESP integer: " + text)
  }
}

///|
/// The boolean line `#t` / `#f`.
fn RespReader::read_bool(self : RespReader) -> Bool raise RespError {
  let text = self.read_line_text()
  match text {
    "t" => true
    "f" => false
    _ => raise RespError("invalid RESP boolean: " + text)
  }
}

///|
/// A bulk string (`$`) or bulk error (`!`): a length line then that many bytes and a
/// CRLF. Length `-1` on a bulk string is the RESP2 null.
fn RespReader::read_bulk(
  self : RespReader,
  is_error : Bool,
) -> RespValue raise RespError {
  let len = self.read_line_int().to_int()
  if len < 0 {
    return Null
  }
  let body = self.take(len)
  self.expect_crlf()
  if is_error {
    BulkError(@utf8.decode_lossy(body[:]))
  } else {
    BulkString(body)
  }
}

///|
/// A verbatim string (`=`): a length line then `<fmt>:<data>` and a CRLF, where `fmt`
/// is a three-character content type (`txt`, `mkd`, ...).
fn RespReader::read_verbatim(self : RespReader) -> RespValue raise RespError {
  let len = self.read_line_int().to_int()
  if len < 4 {
    raise RespError("verbatim string too short")
  }
  let body = self.take(len)
  self.expect_crlf()
  let fmt = @utf8.decode_lossy(body[0:3])
  VerbatimString(fmt, body[4:len].to_owned())
}

///|
/// An aggregate's element count (the line after its marker), as a signed `Int` so the
/// caller can tell a RESP2 null array (`-1`) from an empty one (`0`).
fn RespReader::read_count(self : RespReader) -> Int raise RespError {
  self.read_line_int().to_int()
}

///|
/// Read exactly `count` values (a negative count reads none), for an array/set/push.
fn RespReader::read_elems(
  self : RespReader,
  count : Int,
) -> Array[RespValue] raise RespError {
  let out : Array[RespValue] = []
  if count <= 0 {
    return out
  }
  for _i = 0; _i < count; _i = _i + 1 {
    out.push(self.read())
  }
  out
}

///|
/// The `n` key/value pairs of a map (`%`): a count line then `2n` values.
fn RespReader::read_map(
  self : RespReader,
) -> Array[(RespValue, RespValue)] raise RespError {
  let count = self.read_line_int().to_int()
  let out : Array[(RespValue, RespValue)] = []
  if count <= 0 {
    return out
  }
  for _i = 0; _i < count; _i = _i + 1 {
    let key = self.read()
    let value = self.read()
    out.push((key, value))
  }
  out
}

///|
/// Take exactly `n` bytes, advancing the cursor; an error if fewer remain.
fn RespReader::take(self : RespReader, n : Int) -> Bytes raise RespError {
  if self.pos + n > self.data.length() {
    raise RespError("RESP bulk length exceeds available bytes")
  }
  let body = self.data[self.pos:self.pos + n].to_owned()
  self.pos += n
  body
}

///|
/// Require the next two bytes to be CRLF.
fn RespReader::expect_crlf(self : RespReader) -> Unit raise RespError {
  if self.pos + 2 > self.data.length() ||
    self.data[self.pos] != b'\r' ||
    self.data[self.pos + 1] != b'\n' {
    raise RespError("expected CRLF")
  }
  self.pos += 2
}

///|
/// Parse a RESP3 double line, honouring the `inf` / `-inf` / `nan` spellings.
fn resp_parse_double(text : String) -> RespValue raise RespError {
  let value = match text {
    "inf" => @double.infinity
    "+inf" => @double.infinity
    "-inf" => @double.neg_infinity
    "nan" => @double.not_a_number
    _ =>
      @string.parse_double(text) catch {
        _ => raise RespError("invalid RESP double: " + text)
      }
  }
  Double(value)
}

///|
/// Append a signed decimal integer to `buf`.
fn resp_write_int(buf : Buffer, n : Int64) -> Unit {
  buf.write_bytes(@utf8.encode(n.to_string()))
  resp_write_crlf(buf)
}

///|
/// Append a CRLF to `buf`.
fn resp_write_crlf(buf : Buffer) -> Unit {
  buf.write_byte(b'\r')
  buf.write_byte(b'\n')
}
