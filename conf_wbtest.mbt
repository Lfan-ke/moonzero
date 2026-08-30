///|
/// A go-zero `etc/*.yaml` as `goctl` writes one: every key PascalCase, the log
/// level nested under `Log`, middleware flags under `Middlewares`.
fn gozero_yaml() -> String {
  (
    #|Name: greet-api
    #|Host: 127.0.0.1
    #|Port: 9000
    #|Timeout: 5000
    #|MaxConns: 500
    #|MaxBytes: 2048
    #|CpuThreshold: 800
    #|Verbose: true
    #|CertFile: /etc/tls/server.crt
    #|KeyFile: /etc/tls/server.key
    #|TraceIgnorePaths:
    #|  - /healthz
    #|  - /metrics
    #|Log:
    #|  Level: error
    #|  Mode: console
    #|Middlewares:
    #|  Prometheus: false
    #|  Gunzip: false
    #|Signature:
    #|  Strict: false
    #|  Expiry: 1800000
    #|  PrivateKeys:
    #|    - Fingerprint: qwe
    #|      KeyFile: /etc/keys/qwe.pem
  )
}

///|
test "canonical key folds case and separators" {
  assert_eq(canonical_key("MaxBytes"), "maxbytes")
  assert_eq(canonical_key("max_bytes"), "maxbytes")
  assert_eq(canonical_key("max-bytes"), "maxbytes")
  assert_eq(canonical_key("maxBytes"), "maxbytes")
  assert_eq(canonical_key("MAX_BYTES"), "maxbytes")
  // distinct fields stay distinct
  assert_eq(canonical_key("Timeout") == canonical_key("TimeoutMs"), false)
}

///|
test "a go-zero etc/*.yaml loads instead of silently defaulting" {
  let conf = ServiceConf::from_yaml(gozero_yaml())
  assert_eq(conf.name, "greet-api")
  assert_eq(conf.host, "127.0.0.1")
  assert_eq(conf.port, 9000)
  assert_eq(conf.timeout_ms, 5000)
  assert_eq(conf.log_level, Error)
}

///|
test "moonzero's own flat keys still load" {
  let conf = ServiceConf::from_yaml(
    (
      #|name: greet
      #|host: 10.0.0.1
      #|port: 9100
      #|timeout_ms: 1500
      #|log_level: debug
    ),
  )
  assert_eq(conf.name, "greet")
  assert_eq(conf.host, "10.0.0.1")
  assert_eq(conf.port, 9100)
  assert_eq(conf.timeout_ms, 1500)
  assert_eq(conf.log_level, Debug)
}

///|
test "dotted paths reach into nested mappings" {
  let c = Conf::of_yaml(gozero_yaml())
  assert_eq(c.string("Log.Level"), "error")
  assert_eq(c.string("log.level"), "error")
  assert_eq(c.bool("Middlewares.Prometheus"), false)
  assert_eq(c.at("Log.Missing"), None)
  // walking into a scalar is a miss, not a crash
  assert_eq(c.at("Name.Level"), None)
}

///|
test "an env var overrides a file value" {
  let src = "Port: 9000\n"
  assert_eq(Conf::of_yaml(src).int("Port", env="MOONZERO_PORT"), 9000)
  @env.set_env_var("MOONZERO_PORT", "9999")
  defer @env.unset_env_var("MOONZERO_PORT")
  assert_eq(Conf::of_yaml(src).int("Port", env="MOONZERO_PORT"), 9999)
  // and it reaches the loader, not just the reader
  assert_eq(ServiceConf::from_yaml(src).port, 9999)
}

///|
test "an env var set to empty is ignored" {
  @env.set_env_var("MOONZERO_HOST", "")
  defer @env.unset_env_var("MOONZERO_HOST")
  assert_eq(ServiceConf::from_yaml("Host: 10.0.0.1\n").host, "10.0.0.1")
}

///|
test "a field with no default and no value is refused" {
  let c = Conf::of_yaml("Host: 0.0.0.0\n")
  try {
    let _ = c.int("Port")
  } catch {
    ConfigError(msg) => assert_eq(msg, "field Port is not set")
  } noraise {
    _ => fail("a required field must not fall back to anything")
  }
  // a default makes the same read succeed
  assert_eq(c.int("Port", default=8888), 8888)
}

///|
test "a value outside options= is refused" {
  try {
    let _ = ServiceConf::from_yaml("Log:\n  Level: chatty\n")
  } catch {
    ConfigError(msg) =>
      assert_eq(
        msg, "value \"chatty\" for field Log.Level is not defined in options",
      )
  } noraise {
    _ => fail("an unknown log level must not degrade into info")
  }
}

///|
test "a value outside range= is refused, and the bound itself is not" {
  let c = Conf::of_yaml("CpuThreshold: 1200\n")
  try {
    let _ = c.int64("CpuThreshold", default=900L, range="[0:1000]")
  } catch {
    ConfigError(msg) =>
      assert_eq(
        msg, "value 1200 for field CpuThreshold is out of range [0:1000]",
      )
  } noraise {
    _ => fail("an out-of-range threshold must not load")
  }
  let ok = Conf::of_yaml("CpuThreshold: 1000\n")
  assert_eq(ok.int64("CpuThreshold", default=900L, range="[0:1000]"), 1000L)
}

///|
test "range spec brackets decide whether the bound is included" {
  let closed = range_parse("[0:10]")
  assert_eq(closed.contains(0.0), true)
  assert_eq(closed.contains(10.0), true)
  assert_eq(closed.contains(10.5), false)
  let open = range_parse("(0:10)")
  assert_eq(open.contains(0.0), false)
  assert_eq(open.contains(10.0), false)
  assert_eq(open.contains(5.0), true)
  let half = range_parse("[0:10)")
  assert_eq(half.contains(0.0), true)
  assert_eq(half.contains(10.0), false)
  // an empty end is unbounded
  let up = range_parse("[0:]")
  assert_eq(up.contains(1.0e9), true)
  assert_eq(up.contains(-1.0), false)
  try {
    let _ = range_parse("0:10")
  } catch {
    ConfigError(_) => ()
  } noraise {
    _ => fail("a spec without brackets is not a range")
  }
}

///|
test "typed readers coerce and refuse" {
  let c = Conf::of_yaml(
    (
      #|Port: "8888"
      #|Verbose: true
      #|Name: greet
    ),
  )
  // a quoted number still reads as a number, which is how an env override arrives
  assert_eq(c.int("Port"), 8888)
  assert_eq(c.bool("Verbose"), true)
  // an env override arrives as a string, booleans included
  @env.set_env_var("MOONZERO_VERBOSE", "true")
  defer @env.unset_env_var("MOONZERO_VERBOSE")
  assert_eq(
    Conf::of_yaml("Verbose: false\n").bool("Verbose", env="MOONZERO_VERBOSE"),
    true,
  )
  try {
    let _ = c.int("Name")
  } catch {
    ConfigError(msg) => assert_eq(msg, "field Name must be a number")
  } noraise {
    _ => fail("a non-numeric string is not a number")
  }
  try {
    let _ = c.bool("Name")
  } catch {
    ConfigError(msg) => assert_eq(msg, "field Name must be a boolean")
  } noraise {
    _ => fail("a non-boolean string is not a boolean")
  }
}

///|
test "string lists load from a sequence, from a comma-separated env, or default" {
  let c = Conf::of_yaml(gozero_yaml())
  assert_eq(c.strings("TraceIgnorePaths"), ["/healthz", "/metrics"])
  assert_eq(c.strings("Missing", default=[]), [])
  @env.set_env_var("MOONZERO_IGNORE", "/a, /b ,,/c")
  defer @env.unset_env_var("MOONZERO_IGNORE")
  assert_eq(c.strings("TraceIgnorePaths", env="MOONZERO_IGNORE"), [
    "/a", "/b", "/c",
  ])
}

///|
test "a list of mappings reads back through the same accessors" {
  let c = Conf::of_yaml(gozero_yaml())
  let keys = c.list("Signature.PrivateKeys")
  assert_eq(keys.length(), 1)
  assert_eq(keys[0].string("Fingerprint"), "qwe")
  assert_eq(keys[0].string("KeyFile"), "/etc/keys/qwe.pem")
  assert_eq(c.list("Signature.Missing").length(), 0)
}

///|
test "an explicit null falls back to the default" {
  let c = Conf::of_yaml("Host:\nPort: 9000\n")
  assert_eq(c.string("Host", default="0.0.0.0"), "0.0.0.0")
}
