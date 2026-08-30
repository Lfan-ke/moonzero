// A redis client over the self-built RESP codec: a `RedisConn` carries an encoded
// command to a redis and hands back the decoded reply, and `RedisClient` wraps it with
// the typed commands the rest of the package needs — SET ... EX, GET, DEL, EXPIRE,
// SCAN and PING for the discovery driver, EVAL / EVALSHA / SCRIPT LOAD for the Lua the
// shared limiters run. The connection is an interface, so the same client drives a real
// redis over a socket (`discov`'s `RedisSocket`, which implements it) or an in-process
// fake in a test, and the command/reply logic here runs on every backend.

///|
/// A redis command that failed — a connection-level error, or a redis error reply.
pub suberror RedisError {
  RedisError(String)
}

///|
/// A live redis connection: it sends an encoded command (an array of argument byte
/// strings) and returns the decoded reply. Implementations own the transport — a real
/// socket speaking RESP, or an in-memory fake. It is open and `async` so that a socket
/// can be one: real redis I/O suspends, and a sealed synchronous trait left every
/// implementation a test double.
pub(open) trait RedisConn {
  async fn execute(Self, Array[Bytes]) -> RespValue
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
pub async fn RedisClient::command(
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
pub async fn RedisClient::ping(self : RedisClient) -> String raise RedisError {
  match self.command([b"PING"]) {
    SimpleString(s) => s
    BulkString(b) => @utf8.decode_lossy(b[:])
    other => raise RedisError("unexpected PING reply: " + resp_kind(other))
  }
}

///|
/// `SET key value EX ttl`: store `value` at `key` with a `ttl`-second expiry, the
/// lease a registered instance is held alive by.
pub async fn RedisClient::set_ex(
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
pub async fn RedisClient::get(
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
pub async fn RedisClient::expire(
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
pub async fn RedisClient::del(
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
pub async fn RedisClient::scan_match(
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
/// `SCRIPT LOAD source`: put `source` in the server's script cache and return the SHA1
/// it answers to from then on.
pub async fn RedisClient::script_load(
  self : RedisClient,
  source : String,
) -> String raise RedisError {
  match self.command([b"SCRIPT", b"LOAD", @utf8.encode(source)]) {
    BulkString(b) => @utf8.decode_lossy(b[:])
    SimpleString(s) => s
    other =>
      raise RedisError("unexpected SCRIPT LOAD reply: " + resp_kind(other))
  }
}

///|
/// `EVAL source numkeys key... arg...`: run a Lua script server-side, where the whole
/// script travels with the call.
pub async fn RedisClient::eval(
  self : RedisClient,
  source : String,
  keys : Array[Bytes],
  args : Array[Bytes],
) -> RespValue raise RedisError {
  self.command(script_args(b"EVAL", @utf8.encode(source), keys, args))
}

///|
/// `EVALSHA sha numkeys key... arg...`: run a script the server already holds. A server
/// that has forgotten it answers `NOSCRIPT`, which surfaces as a `RedisError`.
pub async fn RedisClient::evalsha(
  self : RedisClient,
  sha : String,
  keys : Array[Bytes],
  args : Array[Bytes],
) -> RespValue raise RedisError {
  self.command(script_args(b"EVALSHA", @utf8.encode(sha), keys, args))
}

///|
/// The argument vector of an `EVAL`/`EVALSHA`: the verb, the script (source or SHA1),
/// how many of the trailing arguments are keys, then the keys and the rest.
fn script_args(
  verb : Bytes,
  script : Bytes,
  keys : Array[Bytes],
  args : Array[Bytes],
) -> Array[Bytes] {
  let out = [verb, script, @utf8.encode(keys.length().to_string())]
  for key in keys {
    out.push(key)
  }
  for arg in args {
    out.push(arg)
  }
  out
}

///|
/// A Lua script bound to its SHA1 (← go-redis's `Script`, the shape go-zero's
/// `ScriptRun` drives). The first run `SCRIPT LOAD`s the source and keeps the digest,
/// every later run is an `EVALSHA` that ships a 40-byte hash instead of the whole
/// program, and a server that has forgotten it — a restart, a `SCRIPT FLUSH` — answers
/// `NOSCRIPT`, which loads it again and retries once.
pub struct RedisScript {
  source : String
  mut sha : String?
}

///|
/// A script over `source`, not yet loaded anywhere.
pub fn RedisScript::new(source : String) -> RedisScript {
  { source, sha: None, }
}

///|
/// The Lua this script runs.
pub fn RedisScript::source(self : RedisScript) -> String {
  self.source
}

///|
/// Run the script on `client` over `keys` and `args`, loading it first if its digest is
/// not known yet or the server has dropped it.
pub async fn RedisScript::run(
  self : RedisScript,
  client : RedisClient,
  keys : Array[Bytes],
  args : Array[Bytes],
) -> RespValue raise RedisError {
  let sha = match self.sha {
    Some(cached) => cached
    None => self.load(client)
  }
  client.evalsha(sha, keys, args) catch {
    RedisError(msg) =>
      if is_noscript(msg) {
        client.evalsha(self.load(client), keys, args)
      } else {
        raise RedisError(msg)
      }
  }
}

///|
/// `SCRIPT LOAD` the source and remember the digest the server addressed it by.
async fn RedisScript::load(
  self : RedisScript,
  client : RedisClient,
) -> String raise RedisError {
  let sha = client.script_load(self.source)
  self.sha = Some(sha)
  sha
}

///|
/// Whether a redis error is the `NOSCRIPT` an unknown digest draws.
fn is_noscript(msg : String) -> Bool {
  let tag = "NOSCRIPT"
  msg.length() >= tag.length() && msg[0:tag.length()].to_owned() == tag
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
