// RESP over a real TCP socket: the redis connection the discovery flow and the shared
// limiters drive against a live redis. It reuses the root's pure RESP codec
// (`resp_encode_command` to frame a command, `RespValue::decode` to parse a reply) and
// only adds the async send and the framed receive, then hands itself to the root as a
// `RedisConn` — so `RedisClient`, `RedisDiscovery`, `RedisPeriodLimit` and
// `RedisTokenLimit` all run against a real server through this file. Native-only,
// because `moonbitlang/async` has no JS/Wasm backend.

///|
/// A framing or connection error on a RESP socket.
pub suberror RedisSocketError {
  RedisSocketError(String)
}

///|
/// A live connection to a redis server over TCP, speaking RESP.
pub struct RedisSocket {
  tcp : @socket.Tcp
}

///|
/// Open a RESP connection to `host:port`.
pub async fn RedisSocket::connect(host : String, port : Int) -> RedisSocket {
  let addr = @socket.Addr::resolve(host, port~)
  let tcp = @socket.Tcp::connect(addr)
  { tcp, }
}

///|
/// Close the connection.
pub fn RedisSocket::close(self : RedisSocket) -> Unit {
  self.tcp.close()
}

///|
/// Send `args` as a RESP command and read back the decoded reply — the same wire a
/// redis client speaks, carried over the real socket.
pub async fn RedisSocket::execute(
  self : RedisSocket,
  args : Array[Bytes],
) -> @moonzero.RespValue {
  (self.tcp : &@io.Writer).write(@moonzero.resp_encode_command(args))
  let buf = Buffer()
  self.read_frame(buf)
  @moonzero.RespValue::decode(buf.to_bytes())
}

///|
/// The socket is what a `RedisClient` — and through it a discovery driver or a shared
/// limiter — sends its commands over.
impl @moonzero.RedisConn for RedisSocket with fn execute(self, args) {
  self.execute(args)
}

///|
/// A `RedisClient` on this socket: the handle production code builds a
/// `RedisDiscovery`, a `RedisPeriodLimit` or a `RedisTokenLimit` over to have them run
/// against a real server.
pub fn RedisSocket::client(self : RedisSocket) -> @moonzero.RedisClient {
  @moonzero.RedisClient::new(self)
}

///|
/// Send a command given string arguments (command names, keys, and dial addresses are
/// text) and read back the decoded reply.
pub async fn RedisSocket::command(
  self : RedisSocket,
  args : Array[String],
) -> @moonzero.RespValue {
  (self.tcp : &@io.Writer).write(@moonzero.resp_command(args))
  let buf = Buffer()
  self.read_frame(buf)
  @moonzero.RespValue::decode(buf.to_bytes())
}

///|
/// Read one complete RESP frame off the socket into `buf` — following the type marker
/// to know how many more bytes (a bulk body) or elements (an aggregate) to pull, so the
/// accumulated bytes are exactly what the pure decoder expects. Recurses for the
/// elements of arrays, sets, pushes, and maps.
async fn RedisSocket::read_frame(self : RedisSocket, buf : Buffer) -> Unit {
  let line = self.read_line(buf)
  guard line.length() > 0 else { raise RedisSocketError("empty RESP line") }
  match line[0] {
    b'$' | b'!' | b'=' => {
      let len = resp_socket_parse_len(line)
      if len >= 0 {
        buf.write_bytes((self.tcp : &@io.Reader).read_exactly(len + 2))
      }
    }
    b'*' | b'~' | b'>' => {
      let count = resp_socket_parse_len(line)
      for i = 0; i < count; i = i + 1 {
        self.read_frame(buf)
      }
    }
    b'%' => {
      let count = resp_socket_parse_len(line)
      for i = 0; i < count * 2; i = i + 1 {
        self.read_frame(buf)
      }
    }
    _ => ()
  }
}

///|
/// Read one CRLF-terminated line off the socket, appending its bytes (CRLF included) to
/// `buf` and returning the line content without the CRLF — the header the frame reader
/// inspects. The socket's reader buffers internally, so reading a byte at a time is
/// cheap.
async fn RedisSocket::read_line(self : RedisSocket, buf : Buffer) -> Bytes {
  let line = Buffer()
  for ;; {
    let chunk = (self.tcp : &@io.Reader).read_exactly(1)
    guard chunk.length() == 1 else {
      raise RedisSocketError("connection closed mid-line")
    }
    let byte = chunk[0]
    buf.write_byte(byte)
    if byte == b'\n' {
      break
    }
    line.write_byte(byte)
  }
  let content = line.to_bytes()
  // Strip a trailing CR the loop copied before the LF.
  if content.length() > 0 && content[content.length() - 1] == b'\r' {
    content[0:content.length() - 1].to_owned()
  } else {
    content
  }
}

///|
/// Parse the signed integer following a RESP length/count marker (`$5`, `*-1`, ...).
fn resp_socket_parse_len(line : Bytes) -> Int {
  let mut i = 1
  let mut neg = false
  if i < line.length() && line[i] == b'-' {
    neg = true
    i += 1
  }
  let mut n = 0
  while i < line.length() {
    let d = line[i].to_int() - 0x30
    if d < 0 || d > 9 {
      break
    }
    n = n * 10 + d
    i += 1
  }
  if neg {
    -n
  } else {
    n
  }
}
