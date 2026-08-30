// An in-memory redis, complete enough to be a limiter's server: a keyspace that really
// expires, the commands the client issues, and an evaluator for the two Lua scripts
// moonzero ships. The evaluators run through the same command dispatch as everything
// else, over the same keys, so two limiters pointed at one key are sharing real stored
// state rather than a counter the double keeps on the side. It lives here rather than
// beside the root package because `RedisConn` is async now, and only `discov` can run
// an async test.

///|
/// A connection that is simply gone, so a limiter's fallback path can be exercised.
suberror FakeDown

///|
/// A redis keyspace in a `Map`, with expiry against a clock the test advances by hand.
/// `fails` cuts the connection; `evals` and `evalshas` count how each script call went
/// out, which is how the `SCRIPT LOAD` / `EVALSHA` caching is observed.
struct FakeRedis {
  store : Map[String, Bytes]
  expiry : Map[String, Int64]
  scripts : Map[String, String]
  mut now : Int64
  mut fails : Bool
  mut evals : Int
  mut evalshas : Int
}

///|
fn FakeRedis::new() -> FakeRedis {
  {
    store: Map([]),
    expiry: Map([]),
    scripts: Map([]),
    now: 0L,
    fails: false,
    evals: 0,
    evalshas: 0,
  }
}

///|
/// Move the server's clock on by `secs`, expiring whatever has fallen due.
fn FakeRedis::advance(self : FakeRedis, secs : Int64) -> Unit {
  self.now = self.now + secs
  let dead : Array[String] = []
  for key, at in self.expiry {
    if at <= self.now {
      dead.push(key)
    }
  }
  for key in dead {
    self.store.remove(key)
    self.expiry.remove(key)
  }
}

///|
impl @moonzero.RedisConn for FakeRedis with fn execute(self, args) {
  guard !self.fails else { raise FakeDown }
  self.run(args)
}

///|
/// Dispatch one command against the keyspace.
fn FakeRedis::run(
  self : FakeRedis,
  args : Array[Bytes],
) -> @moonzero.RespValue raise {
  guard args.length() > 0 else { return @moonzero.Error("empty command") }
  match text(args[0]) {
    "PING" => @moonzero.SimpleString("PONG")
    "SET" => {
      self.store[text(args[1])] = args[2]
      if args.length() >= 5 && text(args[3]) == "EX" {
        self.expiry[text(args[1])] = self.now + int_of(args[4])
      }
      @moonzero.SimpleString("OK")
    }
    "SETEX" => {
      self.store[text(args[1])] = args[3]
      self.expiry[text(args[1])] = self.now + int_of(args[2])
      @moonzero.SimpleString("OK")
    }
    "GET" =>
      match self.store.get(text(args[1])) {
        Some(v) => @moonzero.BulkString(v)
        None => @moonzero.Null
      }
    "INCRBY" => {
      let key = text(args[1])
      let base = match self.store.get(key) {
        Some(v) => int_of(v)
        None => 0L
      }
      let next = base + int_of(args[2])
      self.store[key] = @utf8.encode(next.to_string())
      @moonzero.Integer(next)
    }
    "EXPIRE" => {
      let key = text(args[1])
      if self.store.contains(key) {
        self.expiry[key] = self.now + int_of(args[2])
        @moonzero.Integer(1)
      } else {
        @moonzero.Integer(0)
      }
    }
    "TTL" => {
      let key = text(args[1])
      if !self.store.contains(key) {
        @moonzero.Integer(-2)
      } else {
        match self.expiry.get(key) {
          Some(at) => @moonzero.Integer(at - self.now)
          None => @moonzero.Integer(-1)
        }
      }
    }
    "DEL" => {
      let mut gone = 0L
      for i = 1; i < args.length(); i = i + 1 {
        let key = text(args[i])
        if self.store.contains(key) {
          self.store.remove(key)
          self.expiry.remove(key)
          gone += 1L
        }
      }
      @moonzero.Integer(gone)
    }
    "SCAN" => {
      let pattern = text(args[3])
      let keys : Array[@moonzero.RespValue] = []
      for k, _ in self.store {
        if glob_match(pattern, k) {
          keys.push(@moonzero.BulkString(@utf8.encode(k)))
        }
      }
      @moonzero.Array([@moonzero.BulkString(b"0"), @moonzero.Array(keys)])
    }
    "SCRIPT" =>
      if text(args[1]) == "LOAD" {
        let source = text(args[2])
        let sha = digest(source)
        self.scripts[sha] = source
        @moonzero.BulkString(@utf8.encode(sha))
      } else {
        @moonzero.Error("ERR unsupported SCRIPT subcommand")
      }
    "EVAL" => {
      self.evals = self.evals + 1
      let (keys, argv) = split_script_args(args)
      self.eval(text(args[1]), keys, argv)
    }
    "EVALSHA" => {
      self.evalshas = self.evalshas + 1
      match self.scripts.get(text(args[1])) {
        Some(source) => {
          let (keys, argv) = split_script_args(args)
          self.eval(source, keys, argv)
        }
        None => @moonzero.Error("NOSCRIPT No matching script. Please use EVAL.")
      }
    }
    other => @moonzero.Error("unknown command " + other)
  }
}

///|
/// Run one of the two scripts moonzero ships, matched on the source text it sent, so a
/// limiter that alters its script or its argument order stops being understood here.
fn FakeRedis::eval(
  self : FakeRedis,
  source : String,
  keys : Array[Bytes],
  argv : Array[Bytes],
) -> @moonzero.RespValue raise {
  if source == @moonzero.period_script {
    self.eval_period(keys, argv)
  } else if source == @moonzero.token_script {
    self.eval_token(keys, argv)
  } else {
    @moonzero.Error(
      "ERR this fake only evaluates moonzero's two limiter scripts",
    )
  }
}

///|
/// `periodscript.lua`: INCRBY the key, hang the window on it the first time round, and
/// report 1 below quota / 2 at it / 0 past it.
fn FakeRedis::eval_period(
  self : FakeRedis,
  keys : Array[Bytes],
  argv : Array[Bytes],
) -> @moonzero.RespValue raise {
  let limit = int_of(argv[0])
  let window = argv[1]
  let current = match self.run([b"INCRBY", keys[0], b"1"]) {
    @moonzero.Integer(n) => n
    _ => 0L
  }
  if current == 1L {
    let _ = self.run([b"EXPIRE", keys[0], window])
  }
  if current < limit {
    @moonzero.Integer(1)
  } else if current == limit {
    @moonzero.Integer(2)
  } else {
    @moonzero.Integer(0)
  }
}

///|
/// `tokenscript.lua`: refill by the seconds elapsed, capped at capacity, spend the
/// request if the tokens are there, and write the bucket and its timestamp back under a
/// TTL of two fill times. Lua's `false` leaves redis as a null reply, its `true` as `1`.
fn FakeRedis::eval_token(
  self : FakeRedis,
  keys : Array[Bytes],
  argv : Array[Bytes],
) -> @moonzero.RespValue raise {
  let rate = num_of(argv[0])
  let capacity = num_of(argv[1])
  let now = num_of(argv[2])
  let requested = num_of(argv[3])
  let ttl = @utf8.encode((capacity / rate * 2.0).to_int().to_string())
  let last_tokens = match self.run([b"GET", keys[0]]) {
    @moonzero.BulkString(v) => num_of(v)
    _ => capacity
  }
  let last_refreshed = match self.run([b"GET", keys[1]]) {
    @moonzero.BulkString(v) => num_of(v)
    _ => 0.0
  }
  let delta = if now - last_refreshed > 0.0 {
    now - last_refreshed
  } else {
    0.0
  }
  let filled_raw = last_tokens + delta * rate
  let filled = if filled_raw < capacity { filled_raw } else { capacity }
  let allowed = filled >= requested
  let new_tokens = if allowed { filled - requested } else { filled }
  let _ = self.run([
    b"SETEX",
    keys[0],
    ttl,
    @utf8.encode(new_tokens.to_string()),
  ])
  let _ = self.run([b"SETEX", keys[1], ttl, @utf8.encode(now.to_string())])
  if allowed {
    @moonzero.Integer(1)
  } else {
    @moonzero.Null
  }
}

///|
/// Split an `EVAL`/`EVALSHA` argument vector into its `KEYS` and its `ARGV`, reading the
/// key count off the wire the way redis does.
fn split_script_args(args : Array[Bytes]) -> (Array[Bytes], Array[Bytes]) {
  let n = int_of(args[2]).to_int()
  let keys : Array[Bytes] = []
  let argv : Array[Bytes] = []
  for i = 3; i < args.length(); i = i + 1 {
    if i < 3 + n {
      keys.push(args[i])
    } else {
      argv.push(args[i])
    }
  }
  (keys, argv)
}

///|
/// A stable 40-hex-character digest standing in for the SHA1 redis addresses a script
/// by; the shape is what matters, not the algorithm.
fn digest(source : String) -> String {
  let hash = @moonzero.sha256(@utf8.encode(source))
  let hex = StringBuilder()
  for i = 0; i < 20; i = i + 1 {
    let b = hash[i].to_int()
    hex.write_char(hex_digit(b / 16))
    hex.write_char(hex_digit(b % 16))
  }
  hex.to_string()
}

///|
fn hex_digit(n : Int) -> Char {
  if n < 10 {
    (48 + n).unsafe_to_char()
  } else {
    (87 + n).unsafe_to_char()
  }
}

///|
fn text(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
/// A stored or argument number as an integer; a value that is not one reads as zero,
/// which is what `tonumber` folding to `nil` amounts to at these call sites.
fn int_of(b : Bytes) -> Int64 {
  @string.parse_int64(text(b)) catch {
    _ => 0L
  }
}

///|
fn num_of(b : Bytes) -> Double {
  @string.parse_double(text(b)) catch {
    _ => 0.0
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
async test "redis discovery: register two instances, resolve both, then deregister" {
  let disc = @moonzero.RedisDiscovery::new(
    @moonzero.RedisClient::new(FakeRedis::new()),
  )
  // Two instances of one service coexist under distinct per-address keys.
  let _ = disc.register("greeter", @moonzero.Endpoint::new("10.0.0.1", 9090))
  let _ = disc.register("greeter", @moonzero.Endpoint::new("10.0.0.2", 9090))
  let eps = disc.resolve("greeter")
  assert_eq(eps.length(), 2)
  let addrs = eps.map(e => e.address())
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // An unregistered service resolves to nothing.
  assert_eq(disc.resolve("other").length(), 0)
  // A service whose name is a prefix of another does not bleed across the `/` boundary.
  let _ = disc.register("greet", @moonzero.Endpoint::new("10.0.0.9", 7000))
  assert_eq(disc.resolve("greeter").length(), 2)
  assert_eq(disc.resolve("greet").length(), 1)
  // The Resolve interface value the balancer consumes sees the last resolved set.
  assert_eq(disc.resolver()("greeter").length(), 2)
  // A keep-alive on a live instance succeeds; on a gone one it reports lapsed.
  assert_eq(
    disc.keepalive("greeter", @moonzero.Endpoint::new("10.0.0.1", 9090)),
    true,
  )
  assert_eq(
    disc.keepalive("greeter", @moonzero.Endpoint::new("10.0.0.7", 9090)),
    false,
  )
  // Deregistering one instance leaves the other; deregistering the service clears it.
  disc.deregister_instance("greeter", @moonzero.Endpoint::new("10.0.0.1", 9090))
  assert_eq(disc.resolve("greeter").length(), 1)
  disc.deregister("greeter")
  assert_eq(disc.resolve("greeter").length(), 0)
}

///|
async test "redis discovery: PING and RESP command encoding round-trip" {
  let client = @moonzero.RedisClient::new(FakeRedis::new())
  assert_eq(client.ping(), "PONG")
  // SET then GET returns the stored bytes; a missing key is None.
  client.set_ex(b"k", b"v", 30)
  assert_eq(client.get(b"k"), Some(b"v"))
  assert_eq(client.get(b"absent"), None)
  assert_eq(client.del([b"k"]), 1)
  assert_eq(client.get(b"k"), None)
}

///|
/// A registered key is held by a lease, so it has to go when the lease does.
async test "redis discovery: a registration lapses when its TTL runs out" {
  let redis = FakeRedis::new()
  let disc = @moonzero.RedisDiscovery::new(@moonzero.RedisClient::new(redis))
  let ep = @moonzero.Endpoint::new("10.0.0.1", 9090)
  let _ = disc.register("greeter", ep, ttl=10)
  assert_eq(disc.resolve("greeter").length(), 1)
  redis.advance(11L)
  assert_eq(disc.resolve("greeter").length(), 0)
  assert_eq(disc.keepalive("greeter", ep), false)
}
