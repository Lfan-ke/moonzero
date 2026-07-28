///|
/// A JSON field accessor for asserting on parsed YAML.
fn field(j : Json, key : String) -> Json {
  match j {
    Object(m) => m.get(key).unwrap()
    _ => abort("not an object")
  }
}

///|
test "yaml parses a flat mapping with typed scalars" {
  let src =
    #|name: greet        # the service name
    #|host: 127.0.0.1
    #|port: 9000
    #|timeout_ms: 1500
    #|enabled: true
    #|ratio: 0.25
    #|note: ~
  let j = yaml_parse(src)
  assert_eq(field(j, "name"), Json::string("greet"))
  assert_eq(field(j, "host"), Json::string("127.0.0.1"))
  assert_eq(field(j, "port"), Json::number(9000.0))
  assert_eq(field(j, "timeout_ms"), Json::number(1500.0))
  assert_eq(field(j, "enabled"), Json::boolean(true))
  assert_eq(field(j, "ratio"), Json::number(0.25))
  assert_eq(field(j, "note"), Json::null())
}

///|
test "yaml parses nested mappings by indentation" {
  let src =
    #|server:
    #|  host: 0.0.0.0
    #|  port: 8080
    #|log:
    #|  level: error
    #|  keep_days: 7
  let j = yaml_parse(src)
  let server = field(j, "server")
  assert_eq(field(server, "host"), Json::string("0.0.0.0"))
  assert_eq(field(server, "port"), Json::number(8080.0))
  assert_eq(field(field(j, "log"), "level"), Json::string("error"))
}

///|
test "yaml parses a scalar list" {
  let src =
    #|hosts:
    #|  - a.example.com
    #|  - b.example.com
    #|  - c.example.com
  let hosts = field(yaml_parse(src), "hosts")
  match hosts {
    Array(xs) => {
      assert_eq(xs.length(), 3)
      assert_eq(xs[0], Json::string("a.example.com"))
      assert_eq(xs[2], Json::string("c.example.com"))
    }
    _ => fail("hosts should be an array")
  }
}

///|
test "yaml parses a list of mappings (multi-key items)" {
  let src =
    #|upstreams:
    #|  - name: auth
    #|    port: 9001
    #|  - name: order
    #|    port: 9002
  let ups = field(yaml_parse(src), "upstreams")
  match ups {
    Array(xs) => {
      assert_eq(xs.length(), 2)
      assert_eq(field(xs[0], "name"), Json::string("auth"))
      assert_eq(field(xs[0], "port"), Json::number(9001.0))
      assert_eq(field(xs[1], "name"), Json::string("order"))
      assert_eq(field(xs[1], "port"), Json::number(9002.0))
    }
    _ => fail("upstreams should be an array")
  }
}

///|
test "yaml round-trips a quoted string with special characters" {
  let src =
    #|greeting: "hello: world # not a comment"
    #|empty: ""
  let j = yaml_parse(src)
  assert_eq(field(j, "greeting"), Json::string("hello: world # not a comment"))
  assert_eq(field(j, "empty"), Json::string(""))
}

///|
test "ServiceConf loads from YAML with lenient defaults" {
  let src =
    #|name: greet
    #|host: 127.0.0.1
    #|port: 9000
    #|timeout_ms: 1500
    #|log_level: error
  let conf = ServiceConf::from_yaml(src)
  assert_eq(conf.name, "greet")
  assert_eq(conf.host, "127.0.0.1")
  assert_eq(conf.port, 9000)
  assert_eq(conf.timeout_ms, 1500)
  assert_eq(conf.log_level, Error)
  // omitted fields fall back to new() defaults, just like the JSON loader
  let partial = ServiceConf::from_yaml("name: only-name")
  assert_eq(partial.host, "0.0.0.0")
  assert_eq(partial.port, 8888)
  assert_eq(partial == ServiceConf::new(name="only-name"), true)
}

///|
test "YAML and JSON configs agree field-for-field" {
  let yaml =
    #|name: svc
    #|port: 7000
    #|log_level: debug
  let json =
    #|{"name":"svc","port":7000,"log_level":"debug"}
  assert_eq(ServiceConf::from_yaml(yaml) == ServiceConf::from_json(json), true)
}

///|
test "yaml loader rejects a non-mapping root" {
  try {
    let _ = ServiceConf::from_yaml("- 1\n- 2\n")
  } catch {
    ConfigError(_) => ()
  } noraise {
    _ => fail("expected a non-mapping root to raise")
  }
}
