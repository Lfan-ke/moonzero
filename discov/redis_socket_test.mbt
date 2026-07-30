// Integration test against a REAL redis. Gated on `MOON_REDIS_TEST`, so it is skipped
// in the normal suite and runs only in the CI job that stands up a redis service
// container. It drives the exact discovery wire — SET with an expiry to register, SCAN
// + GET to resolve, EXPIRE to keep alive, DEL to deregister — over the real socket,
// using the same key layout (`redis_instance_key` / `redis_service_pattern`) the
// in-process driver uses, so a green run proves the RESP codec and the discovery flow
// against a live redis.

///|
/// The redis host for the integration test: `MOON_REDIS_HOST`, or localhost.
fn redis_test_host() -> String {
  match @env.get_env_var("MOON_REDIS_HOST") {
    Some(h) => h
    None => "127.0.0.1"
  }
}

///|
/// SCAN the whole `pattern` keyspace, following the cursor to completion, returning the
/// matched keys as text.
async fn scan_all(sock : RedisSocket, pattern : String) -> Array[String] {
  let out : Array[String] = []
  let mut cursor = "0"
  let mut first = true
  while first || cursor != "0" {
    first = false
    let reply = sock.command(["SCAN", cursor, "MATCH", pattern, "COUNT", "100"])
    match reply {
      @moonzero.Array([c, ks]) => {
        cursor = match c {
          @moonzero.BulkString(b) => @utf8.decode_lossy(b[:])
          _ => "0"
        }
        match ks {
          @moonzero.Array(items) =>
            for it in items {
              match it {
                @moonzero.BulkString(b) => out.push(@utf8.decode_lossy(b[:]))
                _ => ()
              }
            }
          _ => ()
        }
      }
      _ => ()
    }
  }
  out
}

///|
/// Delete every key under `pattern` (idempotent cleanup before a run).
async fn scan_clean(sock : RedisSocket, pattern : String) -> Unit {
  let keys = scan_all(sock, pattern)
  if keys.length() > 0 {
    let args = ["DEL"]
    for k in keys {
      args.push(k)
    }
    let _ = sock.command(args)
  }
}

///|
async test "integration: RESP discovery register/resolve/deregister over a real redis" {
  guard @env.get_env_var("MOON_REDIS_TEST") is Some(_) else { return }
  let sock = RedisSocket::connect(redis_test_host(), 6379)
  defer sock.close()
  // Liveness over the real socket.
  assert_eq(sock.command(["PING"]), @moonzero.SimpleString("PONG"))
  let prefix = "moonzero-ci/"
  let service = "greeter"
  let pattern = @moonzero.redis_service_pattern(prefix, service)
  scan_clean(sock, pattern)
  let ep1 = @moonzero.Endpoint::new("10.0.0.1", 9090)
  let ep2 = @moonzero.Endpoint::new("10.0.0.2", 9090)
  let k1 = @moonzero.redis_instance_key(prefix, service, ep1)
  let k2 = @moonzero.redis_instance_key(prefix, service, ep2)
  // Register: SET <key> <addr> EX 30.
  assert_eq(
    sock.command(["SET", k1, ep1.address(), "EX", "30"]),
    @moonzero.SimpleString("OK"),
  )
  assert_eq(
    sock.command(["SET", k2, ep2.address(), "EX", "30"]),
    @moonzero.SimpleString("OK"),
  )
  // Resolve: SCAN the prefix, GET each value.
  let keys = scan_all(sock, pattern)
  assert_eq(keys.length(), 2)
  let addrs : Array[String] = []
  for key in keys {
    match sock.command(["GET", key]) {
      @moonzero.BulkString(v) => addrs.push(@utf8.decode_lossy(v[:]))
      _ => ()
    }
  }
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // Keep-alive: EXPIRE on a live key reports 1.
  assert_eq(sock.command(["EXPIRE", k1, "60"]), @moonzero.Integer(1))
  // Deregister: DEL both keys, then the prefix scans empty.
  assert_eq(sock.command(["DEL", k1, k2]), @moonzero.Integer(2))
  assert_eq(scan_all(sock, pattern).length(), 0)
}
