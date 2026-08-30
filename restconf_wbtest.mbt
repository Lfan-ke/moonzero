///|
/// An engine over `conf`, on a manual clock and a logger nobody reads, so a test
/// never touches the process logger.
fn test_engine(conf : RestConf) -> RestEngine raise ConfigError {
  let clock = ManualClock::new().as_clock()
  RestEngine::new(conf, clock~, logger=Logger::new(clock, writer=_ => ()))
}

///|
/// The whole chain, in go-zero's order.
fn full_chain() -> Array[String] {
  [
    "trace", "log", "prometheus", "maxConns", "breaker", "shedding", "timeout", "recover",
    "maxBytes",
  ]
}

///|
test "a go-zero rest yaml loads every RestConf field" {
  let conf = RestConf::from_yaml(gozero_yaml())
  assert_eq(conf.service.name, "greet-api")
  assert_eq(conf.host(), "127.0.0.1")
  assert_eq(conf.port(), 9000)
  assert_eq(conf.timeout_ms(), 5000)
  assert_eq(conf.max_conns, 500)
  assert_eq(conf.max_bytes, 2048)
  assert_eq(conf.cpu_threshold, 800L)
  assert_eq(conf.verbose, true)
  assert_eq(conf.cert_file, "/etc/tls/server.crt")
  assert_eq(conf.key_file, "/etc/tls/server.key")
  assert_eq(conf.tls(), true)
  assert_eq(conf.trace_ignore_paths, ["/healthz", "/metrics"])
  assert_eq(conf.signature.strict, false)
  assert_eq(conf.signature.expiry_ms, 1800000L)
  assert_eq(conf.signature.private_keys.length(), 1)
  assert_eq(conf.signature.private_keys[0].fingerprint, "qwe")
  // the two flags the file turns off, and the nine it says nothing about
  assert_eq(conf.middlewares.prometheus, false)
  assert_eq(conf.middlewares.gunzip, false)
  assert_eq(conf.middlewares.trace, true)
  assert_eq(conf.middlewares.max_bytes, true)
}

///|
test "the same config loads from JSON" {
  let conf = RestConf::from_json(
    "{\"Name\":\"api\",\"Port\":8888,\"MaxConns\":7,\"Middlewares\":{\"Breaker\":false}}",
  )
  assert_eq(conf.service.name, "api")
  assert_eq(conf.port(), 8888)
  assert_eq(conf.max_conns, 7)
  assert_eq(conf.middlewares.breaker, false)
}

///|
test "an omitted field takes go-zero's default" {
  let conf = RestConf::from_yaml("Name: api\nPort: 8888\n")
  assert_eq(conf.host(), "0.0.0.0")
  assert_eq(conf.timeout_ms(), 3000)
  assert_eq(conf.max_conns, 10000)
  assert_eq(conf.max_bytes, 1048576)
  assert_eq(conf.cpu_threshold, 900L)
  assert_eq(conf.verbose, false)
  assert_eq(conf.tls(), false)
  assert_eq(conf.signature.expiry_ms, 3600000L)
  assert_eq(conf.middlewares, MiddlewaresConf::new())
  assert_eq(conf.trace_ignore_paths, [])
}

///|
test "a rest service must name itself and its port" {
  for src in ["Port: 8888\n", "Name: api\n"] {
    try {
      let _ = RestConf::from_yaml(src)
    } catch {
      ConfigError(msg) => assert_eq(msg.has_suffix(" is not set"), true)
    } noraise {
      _ => fail("go-zero has no default for Name or Port")
    }
  }
}

///|
test "an out-of-range RestConf value is refused" {
  try {
    let _ = RestConf::from_yaml("Name: api\nPort: 8888\nCpuThreshold: 1200\n")
  } catch {
    ConfigError(msg) =>
      assert_eq(
        msg, "value 1200 for field CpuThreshold is out of range [0:1000]",
      )
  } noraise {
    _ => fail("a threshold above 1000 must not load")
  }
  try {
    let _ = RestConf::from_yaml("Name: api\nPort: 8888\nMaxBytes: 33554433\n")
  } catch {
    ConfigError(msg) =>
      assert_eq(msg.has_suffix("out of range [0:33554432]"), true)
  } noraise {
    _ => fail("a body cap above 32 MiB must not load")
  }
}

///|
test "the chain installs exactly what the flags ask for" {
  let conf = RestConf::from_yaml("Name: api\nPort: 8888\n")
  assert_eq(test_engine(conf).names(), full_chain())

  // each flag drops exactly its own layer
  let off : Array[(MiddlewaresConf, String)] = [
    (MiddlewaresConf::new(trace=false), "trace"),
    (MiddlewaresConf::new(log=false), "log"),
    (MiddlewaresConf::new(prometheus=false), "prometheus"),
    (MiddlewaresConf::new(max_conns=false), "maxConns"),
    (MiddlewaresConf::new(breaker=false), "breaker"),
    (MiddlewaresConf::new(shedding=false), "shedding"),
    (MiddlewaresConf::new(timeout=false), "timeout"),
    (MiddlewaresConf::new(recover=false), "recover"),
    (MiddlewaresConf::new(max_bytes=false), "maxBytes"),
  ]
  for pair in off {
    let names = test_engine(RestConf::new(middlewares=pair.0)).names()
    let want = full_chain().filter(n => n != pair.1)
    assert_eq(names, want)
  }
}

///|
test "the two flags with nothing behind them install nothing either way" {
  // Metrics is go-zero's internal stat sink and Gunzip needs a DEFLATE decoder;
  // moonzero has neither, so both flags load and change no layer
  let on = test_engine(RestConf::new()).names()
  let off = test_engine(
    RestConf::new(middlewares=MiddlewaresConf::new(metrics=false, gunzip=false)),
  ).names()
  assert_eq(on, full_chain())
  assert_eq(off, full_chain())
}

///|
test "a layer whose setting disables it is left out even with its flag on" {
  let conf = RestConf::new(
    max_conns=0,
    max_bytes=0,
    cpu_threshold=0L,
    service=ServiceConf::new(timeout_ms=0),
  )
  assert_eq(test_engine(conf).names(), [
    "trace", "log", "prometheus", "breaker", "recover",
  ])
}

///|
test "the chain the engine builds is the chain it names" {
  let conf = RestConf::from_yaml(gozero_yaml())
  let engine = test_engine(conf)
  // the file turns Prometheus off
  assert_eq(engine.names(), [
    "trace", "log", "maxConns", "breaker", "shedding", "timeout", "recover", "maxBytes",
  ])
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let server = engine.build(app)
  assert_eq(server.describe(), "greet-api listening on 127.0.0.1:9000")
  let _ = server.to_asgi()
}

///|
test "a strict signature with no keys is refused" {
  let strict = RestConf::new(signature=SignatureConf::new(strict=true))
  try {
    let _ = test_engine(strict)
  } catch {
    ConfigError(msg) =>
      assert_eq(msg, "signature is strict but no private keys are configured")
  } noraise {
    _ =>
      fail("go-zero refuses a strict signature config with nothing to verify")
  }
  // with a key it assembles
  let keyed = RestConf::new(
    signature=SignatureConf::new(strict=true, private_keys=[
      { fingerprint: "qwe", key_file: "/k.pem", },
    ]),
  )
  assert_eq(test_engine(keyed).names(), full_chain())
}

///|
test "the engine points the logger at the configured level" {
  let clock = ManualClock::new().as_clock()
  let logger = Logger::new(clock, writer=_ => ())
  let conf = RestConf::from_yaml(gozero_yaml())
  let _ = RestEngine::new(conf, clock~, logger~)
  assert_eq(logger.level(), Error)
}

///|
test "the shedder admits at the threshold and sheds above it" {
  let usage : Ref[Int64] = { val: 0L, }
  let s = Shedder::new(900L, usage=() => usage.val)
  assert_eq(s.allow(), true)
  usage.val = 900L
  assert_eq(s.allow(), true)
  usage.val = 901L
  assert_eq(s.allow(), false)
  // with no meter wired there is nothing to shed on
  assert_eq(Shedder::new(900L).usage(), 0L)
  assert_eq(Shedder::new(900L).allow(), true)
}
