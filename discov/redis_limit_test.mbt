// The shared limiters, driven against the fake redis in `redis_fake_test.mbt` — which
// evaluates the two Lua scripts over a real keyspace rather than answering a constant —
// and, when `MOON_REDIS_TEST` is set, against a live redis over two separate sockets.
// Every test here is about the one property the local limiters cannot have: two limiter
// instances pointed at one key spend one quota between them.

///|
/// The quota is in redis, so it is one quota no matter how many replicas draw on it.
/// The process-local limiter below is the same run in the shape it used to have — six
/// admissions instead of three — which is exactly the bug this replaces.
async test "RedisPeriodLimit: two limiters on one key share one window" {
  let redis = FakeRedis::new()
  let a = @moonzero.RedisPeriodLimit::new(
    @moonzero.RedisClient::new(redis),
    period_secs=60,
    quota=3,
    prefix="limit/",
  )
  let b = @moonzero.RedisPeriodLimit::new(
    @moonzero.RedisClient::new(redis),
    period_secs=60,
    quota=3,
    prefix="limit/",
  )
  assert_eq(a.take("heke1228"), @moonzero.PeriodAllowed)
  assert_eq(b.take("heke1228"), @moonzero.PeriodAllowed)
  assert_eq(a.take("heke1228"), @moonzero.PeriodHitQuota)
  assert_eq(b.take("heke1228"), @moonzero.PeriodOverQuota)
  assert_eq(a.take("heke1228"), @moonzero.PeriodOverQuota)
  // A different key keeps its own window.
  assert_eq(a.take("lfanke"), @moonzero.PeriodAllowed)
  let local_a = @moonzero.PeriodLimit::new(period_secs=60, quota=3)
  let local_b = @moonzero.PeriodLimit::new(period_secs=60, quota=3)
  let mut admitted = 0
  for i = 0; i < 3; i = i + 1 {
    if local_a.take("heke1228", 0L) != @moonzero.PeriodOverQuota {
      admitted += 1
    }
    if local_b.take("heke1228", 0L) != @moonzero.PeriodOverQuota {
      admitted += 1
    }
  }
  assert_eq(admitted, 6)
}

///|
/// The script only sets the expiry on the request that creates the counter, so the
/// window has to be carrying a TTL and has to reopen when it lapses.
async test "RedisPeriodLimit: the window carries the period and reopens after it" {
  let redis = FakeRedis::new()
  let client = @moonzero.RedisClient::new(redis)
  let lim = @moonzero.RedisPeriodLimit::new(client, period_secs=60, quota=2)
  assert_eq(lim.take("qwq"), @moonzero.PeriodAllowed)
  assert_eq(client.command([b"TTL", b"qwq"]), @moonzero.Integer(60))
  assert_eq(lim.take("qwq"), @moonzero.PeriodHitQuota)
  assert_eq(lim.take("qwq"), @moonzero.PeriodOverQuota)
  redis.advance(61L)
  assert_eq(lim.take("qwq"), @moonzero.PeriodAllowed)
}

///|
/// The bucket is in redis, so a burst is spent between replicas, not by each of them.
async test "RedisTokenLimit: two limiters on one key share one bucket" {
  let redis = FakeRedis::new()
  let a = @moonzero.RedisTokenLimit::new(
    @moonzero.RedisClient::new(redis),
    rate=1,
    burst=3,
    key="qwe",
  )
  let b = @moonzero.RedisTokenLimit::new(
    @moonzero.RedisClient::new(redis),
    rate=1,
    burst=3,
    key="qwe",
  )
  assert_eq(a.allow(0L), true)
  assert_eq(b.allow(0L), true)
  assert_eq(a.allow(0L), true)
  assert_eq(b.allow(0L), false)
  assert_eq(a.allow(0L), false)
  // One second of refill at rate 1 puts exactly one token back for the pair to fight over.
  assert_eq(a.allow(1000L), true)
  assert_eq(b.allow(1000L), false)
  // A bucket under a different key is untouched by any of that.
  let other = @moonzero.RedisTokenLimit::new(
    @moonzero.RedisClient::new(redis),
    rate=1,
    burst=3,
    key="orz",
  )
  assert_eq(other.allow(0L), true)
}

///|
/// go-zero keeps limiting when redis goes away rather than opening the gate, by falling
/// back to a process-local bucket. A dead redis must not turn into unlimited traffic.
async test "RedisTokenLimit: an unreachable redis falls back to the local bucket" {
  let redis = FakeRedis::new()
  let lim = @moonzero.RedisTokenLimit::new(
    @moonzero.RedisClient::new(redis),
    rate=1,
    burst=2,
    key="orx",
  )
  assert_eq(lim.allow(0L), true)
  redis.fails = true
  // The rescue bucket is still a limiter: burst 2, then refusals until it refills.
  assert_eq(lim.allow(0L), true)
  assert_eq(lim.allow(0L), true)
  assert_eq(lim.allow(0L), false)
  assert_eq(lim.allow(1000L), true)
  assert_eq(lim.allow(1000L), false)
}

///|
/// The whole program goes over the wire once; after that the limiter sends a digest, and
/// a server that has forgotten the script gets it back rather than failing the request.
async test "the limiter loads its script once and then runs it by digest" {
  let redis = FakeRedis::new()
  let lim = @moonzero.RedisPeriodLimit::new(
    @moonzero.RedisClient::new(redis),
    period_secs=60,
    quota=99,
  )
  let _ = lim.take("hhh")
  let _ = lim.take("hhh")
  assert_eq(redis.evals, 0)
  assert_eq(redis.evalshas, 2)
  redis.scripts.clear()
  assert_eq(lim.take("hhh"), @moonzero.PeriodAllowed)
  // The rejected digest, then the retry after re-loading.
  assert_eq(redis.evalshas, 4)
  assert_eq(redis.evals, 0)
}

///|
/// The middleware is the shape a service actually assembles, so the sharing has to hold
/// through it: two replicas' stacks, one quota, `429` for whoever runs out.
async test "redis_period_limit: two assembled apps share one quota" {
  let redis = FakeRedis::new()
  let app_a = @moonzero.redis_period_limit(
    @moonzero.RedisPeriodLimit::new(
      @moonzero.RedisClient::new(redis),
      period_secs=60,
      quota=2,
    ),
    key="shared",
  )(responder(200))
  let app_b = @moonzero.redis_period_limit(
    @moonzero.RedisPeriodLimit::new(
      @moonzero.RedisClient::new(redis),
      period_secs=60,
      quota=2,
    ),
    key="shared",
  )(responder(200))
  assert_eq(status_of(drive(app_a)), 200)
  assert_eq(status_of(drive(app_b)), 200)
  assert_eq(status_of(drive(app_a)), 429)
  assert_eq(status_of(drive(app_b)), 429)
}

///|
/// A limiter must not be able to close the service it guards, so an unreachable redis
/// admits rather than answering 429 to everything.
async test "redis_period_limit: an unreachable redis admits" {
  let redis = FakeRedis::new()
  let app = @moonzero.redis_period_limit(
    @moonzero.RedisPeriodLimit::new(
      @moonzero.RedisClient::new(redis),
      period_secs=60,
      quota=1,
    ),
    key="shared",
  )(responder(200))
  assert_eq(status_of(drive(app)), 200)
  assert_eq(status_of(drive(app)), 429)
  redis.fails = true
  assert_eq(status_of(drive(app)), 200)
}

///|
async test "redis_rate_limit: two assembled apps share one bucket" {
  let redis = FakeRedis::new()
  let clock = @moonzero.Clock::new(() => 0L)
  let app_a = @moonzero.redis_rate_limit(
    @moonzero.RedisTokenLimit::new(
      @moonzero.RedisClient::new(redis),
      rate=1,
      burst=2,
      key="mw",
    ),
    clock,
  )(responder(200))
  let app_b = @moonzero.redis_rate_limit(
    @moonzero.RedisTokenLimit::new(
      @moonzero.RedisClient::new(redis),
      rate=1,
      burst=2,
      key="mw",
    ),
    clock,
  )(responder(200))
  assert_eq(status_of(drive(app_a)), 200)
  assert_eq(status_of(drive(app_b)), 200)
  assert_eq(status_of(drive(app_a)), 429)
  assert_eq(status_of(drive(app_b)), 429)
}

///|
/// The shared window over a real redis, through two independent connections — the same
/// arrangement two replicas have. Gated on `MOON_REDIS_TEST`.
async test "integration: two period limiters on a live redis share the window" {
  guard @env.get_env_var("MOON_REDIS_TEST") is Some(_) else { return }
  let s1 = RedisSocket::connect(redis_test_host(), 6379)
  defer s1.close()
  let s2 = RedisSocket::connect(redis_test_host(), 6379)
  defer s2.close()
  let prefix = "moonzero-ci-limit/"
  let key = "period"
  let _ = s1.command(["DEL", prefix + key])
  let a = @moonzero.RedisPeriodLimit::new(
    s1.client(),
    period_secs=60,
    quota=3,
    prefix~,
  )
  let b = @moonzero.RedisPeriodLimit::new(
    s2.client(),
    period_secs=60,
    quota=3,
    prefix~,
  )
  assert_eq(a.take(key), @moonzero.PeriodAllowed)
  assert_eq(b.take(key), @moonzero.PeriodAllowed)
  assert_eq(a.take(key), @moonzero.PeriodHitQuota)
  assert_eq(b.take(key), @moonzero.PeriodOverQuota)
  match s1.command(["TTL", prefix + key]) {
    @moonzero.Integer(ttl) => assert_eq(ttl > 0L && ttl <= 60L, true)
    other => fail("unexpected TTL reply: " + @moonzero.resp_kind(other))
  }
  let _ = s1.command(["DEL", prefix + key])
}

///|
/// The shared bucket over a real redis. The instant is fixed rather than read from the
/// clock so the refill step is exact. Gated on `MOON_REDIS_TEST`.
async test "integration: two token limiters on a live redis share the bucket" {
  guard @env.get_env_var("MOON_REDIS_TEST") is Some(_) else { return }
  let s1 = RedisSocket::connect(redis_test_host(), 6379)
  defer s1.close()
  let s2 = RedisSocket::connect(redis_test_host(), 6379)
  defer s2.close()
  let key = "moonzero-ci-limit/token"
  let _ = s1.command(["DEL", "{" + key + "}.tokens", "{" + key + "}.ts"])
  let a = @moonzero.RedisTokenLimit::new(s1.client(), rate=1, burst=3, key~)
  let b = @moonzero.RedisTokenLimit::new(s2.client(), rate=1, burst=3, key~)
  let now = 1700000000000L
  assert_eq(a.allow(now), true)
  assert_eq(b.allow(now), true)
  assert_eq(a.allow(now), true)
  assert_eq(b.allow(now), false)
  assert_eq(a.allow(now), false)
  assert_eq(a.allow(now + 1000L), true)
  assert_eq(b.allow(now + 1000L), false)
  let _ = s1.command(["DEL", "{" + key + "}.tokens", "{" + key + "}.ts"])
}
