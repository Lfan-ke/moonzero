///|
/// A config-loading failure (← go-zero's `conf.Load` errors): malformed JSON or
/// YAML, a non-mapping root, a field of the wrong type, a required field with no
/// value, or a value outside its `options=`/`range=` constraint, with a
/// human-readable reason.
pub suberror ConfigError {
  ConfigError(String)
}

///|
/// Decode a `LogLevel` from a JSON string (`"debug"`/`"info"`/`"error"`/
/// `"severe"`), reusing `LogLevel::parse`'s lenient fallback to `Info`. This impl
/// lets `ServiceConf`'s derived `FromJson` read `log_level` as a plain string —
/// the way go-zero writes it in YAML/JSON config — instead of a tagged variant.
pub impl @json.FromJson for LogLevel with fn from_json(json, path) {
  match json {
    String(s) => LogLevel::parse(s)
    _ => raise @json.JsonDecodeError((path, "log level must be a JSON string"))
  }
}

///|
/// The level names go-zero's `LogConf.Level` accepts (`options=[...]`). A level
/// outside this set is a config error, not a silent fallback.
let log_levels : Array[String] = ["debug", "info", "error", "severe"]

///|
/// Load a `ServiceConf` from a JSON config string, applying go-zero-style
/// defaults for every omitted field (an empty `{}` yields exactly
/// `ServiceConf::new()`). This is the lenient loader mirroring go-zero's
/// `conf.Load` with `,optional`/`,default=` struct tags: unlike the strict
/// derived `FromJson` — reachable via `@json.from_json` and requiring every
/// field present — a partial config is filled from the same defaults `new()`
/// uses.
///
/// Keys are matched canonically, so go-zero's `Name`/`Host`/`Port`/`Timeout` and
/// moonzero's own `timeout_ms`/`log_level` spellings all load.
///
/// Raises `ConfigError` on malformed JSON, a non-object root, a field of the
/// wrong type, or a log level outside `debug|info|error|severe`.
pub fn ServiceConf::from_json(src : String) -> ServiceConf raise ConfigError {
  let def = ServiceConf::new()
  service_conf_of(
    Conf::of_json(src),
    name_default=def.name,
    port_default=def.port,
  )
}

///|
/// Load a `ServiceConf` from a **YAML** config string — the format go-zero
/// actually ships (`etc/*.yaml`) — with the same lenient, default-filling
/// semantics as `from_json`: an empty document yields exactly
/// `ServiceConf::new()`, and each omitted field falls back to its `new()`
/// default. The YAML is parsed by the self-built `yaml_parse` (block mappings,
/// nesting, sequences, scalars, comments) into a `Json` object, then decoded by
/// the shared field reader — so JSON and YAML configs agree field-for-field.
///
/// Raises `ConfigError` on malformed YAML, a non-mapping root, a field of the
/// wrong type, or a log level outside `debug|info|error|severe`.
pub fn ServiceConf::from_yaml(src : String) -> ServiceConf raise ConfigError {
  let def = ServiceConf::new()
  service_conf_of(
    Conf::of_yaml(src),
    name_default=def.name,
    port_default=def.port,
  )
}

///|
/// Decode a `ServiceConf` from a loaded document. Shared by the standalone
/// loaders and by `RestConf`, which differ only in whether `Name` and `Port` have
/// a default: the standalone loaders pass the `new()` values, `RestConf` passes
/// none so a rest service must name itself and its port, as go-zero requires.
///
/// The paths are go-zero's (`Name`, `Host`, `Port`, `Timeout`, `Log.Level`); the
/// alternative spellings are the flat keys moonzero's own configs and examples
/// were written with, kept so those keep loading.
fn service_conf_of(
  c : Conf,
  name_default? : String,
  port_default? : Int,
) -> ServiceConf raise ConfigError {
  let def = ServiceConf::new()
  let name = c.string("Name", default?=name_default, env="MOONZERO_NAME")
  let host = c.string("Host", default=def.host, env="MOONZERO_HOST")
  let port = c.int("Port", default?=port_default, env="MOONZERO_PORT")
  let timeout_ms = c.int(
    "Timeout",
    default=def.timeout_ms,
    env="MOONZERO_TIMEOUT",
    also=["TimeoutMs"],
  )
  let log_level = LogLevel::parse(
    c.string(
      "Log.Level",
      default=def.log_level.to_string(),
      options=log_levels,
      env="MOONZERO_LOG_LEVEL",
      also=["LogLevel"],
    ),
  )
  { name, host, port, timeout_ms, log_level, }
}
