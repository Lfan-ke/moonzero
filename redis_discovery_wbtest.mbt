// A stateful in-memory fake redis (a Map-backed keyspace driven by the real RESP
// commands) so the discovery driver's register -> resolve -> deregister flow round-
// trips through an actual store on every backend. The same RedisDiscovery drives a
// real redis over a RESP socket in the native driver.

///|
/// A fake redis backing PING / SET / GET / DEL / EXPIRE / SCAN with a Map, enough to
/// exercise the discovery driver. Keys are held by their decoded text (discovery keys
/// are ASCII); TTLs are accepted and ignored (nothing expires within a test).
struct FakeRedis {
  store : Map[String, Bytes]
}

///|
fn FakeRedis::new() -> FakeRedis {
  { store: Map([]), }
}

///|
impl RedisConn for FakeRedis with fn execute(self, args) {
  guard args.length() > 0 else { return Error("empty command") }
  let name = @utf8.decode_lossy(args[0][:])
  match name {
    "PING" => SimpleString("PONG")
    "SET" => {
      // SET key value [EX ttl]
      let key = @utf8.decode_lossy(args[1][:])
      self.store[key] = args[2]
      SimpleString("OK")
    }
    "GET" =>
      match self.store.get(@utf8.decode_lossy(args[1][:])) {
        Some(v) => BulkString(v)
        None => Null
      }
    "DEL" => {
      let mut deleted = 0L
      for i = 1; i < args.length(); i = i + 1 {
        let key = @utf8.decode_lossy(args[i][:])
        if self.store.contains(key) {
          self.store.remove(key)
          deleted += 1L
        }
      }
      Integer(deleted)
    }
    "EXPIRE" => {
      let key = @utf8.decode_lossy(args[1][:])
      Integer(if self.store.contains(key) { 1L } else { 0L })
    }
    "SCAN" => {
      // SCAN cursor MATCH pattern COUNT n — return every match in one page.
      let pattern = @utf8.decode_lossy(args[3][:])
      let keys : Array[RespValue] = []
      for k, _ in self.store {
        if glob_match(pattern, k) {
          keys.push(BulkString(@utf8.encode(k)))
        }
      }
      Array([BulkString(b"0"), Array(keys)])
    }
    other => Error("unknown command " + other)
  }
}

///|
/// Redis glob match supporting `*` (any run) and `?` (one char) — the discovery driver
/// only ever scans with a trailing `*`, but a real matcher keeps the fake honest.
fn glob_match(pattern : String, s : String) -> Bool {
  let np = pattern.length()
  let ns = s.length()
  // Backtracking match: `star` remembers the last `*`, `mark` the input position to
  // resume from if the tail fails.
  let mut pi = 0
  let mut si = 0
  let mut star = -1
  let mut mark = 0
  while si < ns {
    if pi < np && (pattern[pi] == s[si] || pattern[pi] == '?') {
      pi += 1
      si += 1
    } else if pi < np && pattern[pi] == '*' {
      star = pi
      mark = si
      pi += 1
    } else if star >= 0 {
      pi = star + 1
      mark += 1
      si = mark
    } else {
      return false
    }
  }
  while pi < np && pattern[pi] == '*' {
    pi += 1
  }
  pi == np
}

///|
test "redis discovery: register two instances, resolve both, then deregister" {
  let disc = RedisDiscovery::new(RedisClient::new(FakeRedis::new()))
  // Two instances of one service coexist under distinct per-address keys.
  let _ = disc.register("greeter", Endpoint::new("10.0.0.1", 9090))
  let _ = disc.register("greeter", Endpoint::new("10.0.0.2", 9090))
  let eps = disc.resolve("greeter")
  assert_eq(eps.length(), 2)
  let addrs = eps.map(e => e.address())
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // An unregistered service resolves to nothing.
  assert_eq(disc.resolve("other").length(), 0)
  // A service whose name is a prefix of another does not bleed across the `/` boundary.
  let _ = disc.register("greet", Endpoint::new("10.0.0.9", 7000))
  assert_eq(disc.resolve("greeter").length(), 2)
  assert_eq(disc.resolve("greet").length(), 1)
  // The Resolve interface value the balancer consumes sees the same set.
  assert_eq(disc.resolver()("greeter").length(), 2)
  // A keep-alive on a live instance succeeds; on a gone one it reports lapsed.
  assert_eq(disc.keepalive("greeter", Endpoint::new("10.0.0.1", 9090)), true)
  assert_eq(disc.keepalive("greeter", Endpoint::new("10.0.0.7", 9090)), false)
  // Deregistering one instance leaves the other; deregistering the service clears it.
  disc.deregister_instance("greeter", Endpoint::new("10.0.0.1", 9090))
  assert_eq(disc.resolve("greeter").length(), 1)
  disc.deregister("greeter")
  assert_eq(disc.resolve("greeter").length(), 0)
}

///|
test "redis discovery: PING and RESP command encoding round-trip" {
  let client = RedisClient::new(FakeRedis::new())
  assert_eq(client.ping(), "PONG")
  // SET then GET returns the stored bytes; a missing key is None.
  client.set_ex(b"k", b"v", 30)
  assert_eq(client.get(b"k"), Some(b"v"))
  assert_eq(client.get(b"absent"), None)
  assert_eq(client.del([b"k"]), 1)
  assert_eq(client.get(b"k"), None)
}
