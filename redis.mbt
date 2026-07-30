// A redis client over the self-built RESP codec: a `RedisConn` carries an encoded
// command to a redis and hands back the decoded reply, and `RedisClient` wraps it with
// the handful of typed commands the discovery driver needs (SET ... EX, GET, DEL,
// EXPIRE, SCAN, PING). The connection is an interface, so the same client drives a
// real redis over a socket (the native `discov` driver) or an in-process fake in a
// test, and the command/reply logic here runs on every backend.

///|
/// A redis command that failed — a connection-level error, or a redis error reply.
pub suberror RedisError {
  RedisError(String)
}

///|
/// A live redis connection: it sends an encoded command (an array of argument byte
/// strings) and returns the decoded reply. Implementations own the transport — a real
/// socket speaking RESP, or an in-memory fake.
pub trait RedisConn {
  fn execute(Self, Array[Bytes]) -> RespValue raise
}

///|
/// A redis client over a `RedisConn`, exposing the typed commands the discovery driver
/// uses. Every command maps a redis error reply to `RedisError`.
pub struct RedisClient {
  conn : &RedisConn
}

///|
/// A client over `conn`.
pub fn RedisClient::new(conn : &RedisConn) -> RedisClient {
  { conn, }
}

///|
/// Send `args` as a command and return the reply, turning a connection failure or a
/// redis `-ERR` reply into `RedisError`.
pub fn RedisClient::command(
  self : RedisClient,
  args : Array[Bytes],
) -> RespValue raise RedisError {
  let reply = self.conn.execute(args) catch {
    e => raise RedisError("redis connection error: " + e.to_string())
  }
  match reply {
    Error(msg) => raise RedisError(msg)
    BulkError(msg) => raise RedisError(msg)
    other => other
  }
}

///|
/// `PING`: the server's `PONG` liveness reply.
pub fn RedisClient::ping(self : RedisClient) -> String raise RedisError {
  match self.command([b"PING"]) {
    SimpleString(s) => s
    BulkString(b) => @utf8.decode_lossy(b[:])
    other => raise RedisError("unexpected PING reply: " + resp_kind(other))
  }
}

///|
/// `SET key value EX ttl`: store `value` at `key` with a `ttl`-second expiry, the
/// lease a registered instance is held alive by.
pub fn RedisClient::set_ex(
  self : RedisClient,
  key : Bytes,
  value : Bytes,
  ttl_secs : Int,
) -> Unit raise RedisError {
  let reply = self.command([
    b"SET",
    key,
    value,
    b"EX",
    @utf8.encode(ttl_secs.to_string()),
  ])
  match reply {
    SimpleString("OK") => ()
    other => raise RedisError("unexpected SET reply: " + resp_kind(other))
  }
}

///|
/// `GET key`: the value at `key`, or `None` if the key is absent or expired.
pub fn RedisClient::get(
  self : RedisClient,
  key : Bytes,
) -> Bytes? raise RedisError {
  match self.command([b"GET", key]) {
    BulkString(b) => Some(b)
    Null => None
    other => raise RedisError("unexpected GET reply: " + resp_kind(other))
  }
}

///|
/// `EXPIRE key ttl`: refresh a key's expiry (the discovery keep-alive). `true` if the
/// key existed and its TTL was set.
pub fn RedisClient::expire(
  self : RedisClient,
  key : Bytes,
  ttl_secs : Int,
) -> Bool raise RedisError {
  match self.command([b"EXPIRE", key, @utf8.encode(ttl_secs.to_string())]) {
    Integer(n) => n == 1
    other => raise RedisError("unexpected EXPIRE reply: " + resp_kind(other))
  }
}

///|
/// `DEL key...`: delete the given keys, returning how many existed (deregistration).
pub fn RedisClient::del(
  self : RedisClient,
  keys : Array[Bytes],
) -> Int64 raise RedisError {
  if keys.length() == 0 {
    return 0
  }
  let args = [b"DEL"]
  for k in keys {
    args.push(k)
  }
  match self.command(args) {
    Integer(n) => n
    other => raise RedisError("unexpected DEL reply: " + resp_kind(other))
  }
}

///|
/// `SCAN`-iterate every key matching `pattern` (a glob like `prefix/*`), following the
/// cursor to completion so the whole keyspace is covered without ever blocking the
/// server on a `KEYS` scan. `count` is the per-step hint passed to redis.
pub fn RedisClient::scan_match(
  self : RedisClient,
  pattern : Bytes,
  count : Int,
) -> Array[Bytes] raise RedisError {
  let out : Array[Bytes] = []
  let mut cursor = b"0"
  // The first iteration always runs; it stops when redis returns cursor "0" again.
  for first = true; first || not_zero_cursor(cursor); first = false {
    let reply = self.command([
      b"SCAN",
      cursor,
      b"MATCH",
      pattern,
      b"COUNT",
      @utf8.encode(count.to_string()),
    ])
    let (next, keys) = parse_scan_reply(reply)
    for k in keys {
      out.push(k)
    }
    cursor = next
  }
  out
}

///|
/// Whether a SCAN cursor is not the terminal `"0"`.
fn not_zero_cursor(cursor : Bytes) -> Bool {
  not_equal_bytes(cursor, b"0")
}

///|
/// Byte-inequality of two byte strings.
fn not_equal_bytes(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return true
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return true
    }
  }
  false
}

///|
/// Split a SCAN reply `[cursor, [key...]]` into the next cursor and its keys.
fn parse_scan_reply(
  reply : RespValue,
) -> (Bytes, Array[Bytes]) raise RedisError {
  match reply {
    Array([cursor, keys]) => {
      let next = match cursor {
        BulkString(b) => b
        SimpleString(s) => @utf8.encode(s)
        other =>
          raise RedisError("SCAN cursor not a string: " + resp_kind(other))
      }
      let out : Array[Bytes] = []
      match keys {
        Array(items) =>
          for item in items {
            match item {
              BulkString(b) => out.push(b)
              other =>
                raise RedisError(
                  "SCAN key not a bulk string: " + resp_kind(other),
                )
            }
          }
        other => raise RedisError("SCAN keys not an array: " + resp_kind(other))
      }
      (next, out)
    }
    other => raise RedisError("unexpected SCAN reply: " + resp_kind(other))
  }
}
