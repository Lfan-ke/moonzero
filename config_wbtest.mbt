///|
test "config round-trip: full JSON string -> ServiceConf (lenient loader)" {
  let src =
    #|{"name":"greet","host":"127.0.0.1","port":9000,"timeout_ms":1500,"log_level":"error"}
  let conf = ServiceConf::from_json(src)
  assert_eq(conf.name, "greet")
  assert_eq(conf.host, "127.0.0.1")
  assert_eq(conf.port, 9000)
  assert_eq(conf.timeout_ms, 1500)
  assert_eq(conf.log_level, Error)
}

///|
test "config round-trip: strict derived FromJson requires every field" {
  let src =
    #|{"name":"api","host":"0.0.0.0","port":8080,"timeout_ms":3000,"log_level":"debug"}
  let conf : ServiceConf = @json.from_json(@json.parse(src))
  assert_eq(conf.name, "api")
  assert_eq(conf.port, 8080)
  assert_eq(conf.log_level, Debug)
  // a partial object is rejected by the strict derived path
  try {
    let _ : ServiceConf = @json.from_json(@json.parse("{\"name\":\"x\"}"))
  } catch {
    _ => ()
  } noraise {
    _ => fail("strict FromJson should reject a partial config")
  }
}

///|
test "lenient loader fills omitted fields from new() defaults" {
  let partial = ServiceConf::from_json("{\"name\":\"only-name\"}")
  assert_eq(partial.name, "only-name")
  assert_eq(partial.host, "0.0.0.0")
  assert_eq(partial.port, 8888)
  assert_eq(partial.timeout_ms, 3000)
  assert_eq(partial.log_level, Info)
  // an empty object yields exactly the defaults
  assert_eq(ServiceConf::from_json("{}") == ServiceConf::new(), true)
}

///|
test "loader rejects malformed input" {
  // not valid JSON
  try {
    let _ = ServiceConf::from_json("{not json")
  } catch {
    ConfigError(_) => ()
  } noraise {
    _ => fail("expected invalid JSON to raise")
  }
  // non-object root
  try {
    let _ = ServiceConf::from_json("[1,2,3]")
  } catch {
    ConfigError(_) => ()
  } noraise {
    _ => fail("expected non-object root to raise")
  }
  // wrong field type
  try {
    let _ = ServiceConf::from_json("{\"port\":\"nope\"}")
  } catch {
    ConfigError(_) => ()
  } noraise {
    _ => fail("expected wrong-typed port to raise")
  }
}

///|
test "log level decodes from a JSON string, and only from the four names" {
  assert_eq(
    ServiceConf::from_json("{\"log_level\":\"severe\"}").log_level,
    Severe,
  )
  // go-zero tags the level `options=[debug,info,error,severe]`, so a name outside
  // that set is a config error rather than a quiet downgrade to info
  try {
    let _ = ServiceConf::from_json("{\"log_level\":\"chatty\"}")
  } catch {
    ConfigError(_) => ()
  } noraise {
    _ => fail("an unknown level must not load as info")
  }
  // LogLevel::parse itself stays lenient: it is the wire decoder, not the loader
  assert_eq(LogLevel::parse("chatty"), Info)
}
