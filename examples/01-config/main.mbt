///|
/// Load a `ServiceConf` three ways — the `new()` defaults, a partial JSON config
/// filled from those defaults, and the YAML `etc/*.yaml` format go-zero ships —
/// then read the `LogLevel` ordering and the raw `yaml_parse` output.
///
///     moon run examples/01-config
#coverage.skip
fn main {
  try {
    let def = @moonzero.ServiceConf::new()
    println("defaults: " + describe(def))

    // A partial JSON config: only the fields present override; the rest fall back
    // to the same defaults `new()` uses (go-zero's `,optional`/`,default=`).
    let json_src =
      #|{ "name": "greet", "port": 9000, "log_level": "error" }
    let from_json = @moonzero.ServiceConf::from_json(json_src)
    println("from_json: " + describe(from_json))

    // The YAML config format go-zero actually writes, decoded through the same
    // lenient field reader so it agrees with JSON field-for-field.
    let yaml_src = "name: greet\nhost: 127.0.0.1\nport: 9000\ntimeout_ms: 1500\nlog_level: debug\n"
    let from_yaml = @moonzero.ServiceConf::from_yaml(yaml_src)
    println("from_yaml: " + describe(from_yaml))

    // LogLevel derives Compare in verbosity order, so thresholds test directly.
    let debug = @moonzero.LogLevel::parse("debug")
    let error = @moonzero.LogLevel::parse("error")
    println(
      "log levels: " +
      debug.to_string() +
      " < " +
      error.to_string() +
      " = " +
      (debug < error).to_string(),
    )
    println(
      "unknown level falls back to: " +
      @moonzero.LogLevel::parse("verbose").to_string(),
    )

    // The self-built YAML parser lowered to the same Json the JSON loader reads.
    let doc = @moonzero.yaml_parse(
      "name: greet\nnested:\n  port: 9000\n  tags:\n    - a\n    - b\n",
    )
    println("yaml_parse -> " + doc.stringify())
  } catch {
    ConfigError(msg) => println("config error: " + msg)
  }
}

///|
fn describe(conf : @moonzero.ServiceConf) -> String {
  conf.name +
  " " +
  conf.host +
  ":" +
  conf.port.to_string() +
  " timeout=" +
  conf.timeout_ms.to_string() +
  "ms level=" +
  conf.log_level.to_string()
}
