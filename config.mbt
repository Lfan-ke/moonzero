///|
/// A config-loading failure (← go-zero's `conf.Load` errors): malformed JSON, a
/// non-object root, or a field of the wrong type, with a human-readable reason.
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
/// Load a `ServiceConf` from a JSON config string, applying go-zero-style
/// defaults for every omitted field (an empty `{}` yields exactly
/// `ServiceConf::new()`). This is the lenient loader mirroring go-zero's
/// `conf.Load` with `,optional`/`,default=` struct tags: unlike the strict
/// derived `FromJson` — reachable via `@json.from_json` and requiring every
/// field present — a partial config is filled from the same defaults `new()`
/// uses.
///
/// Raises `ConfigError` on malformed JSON, a non-object root, or a field of the
/// wrong type.
pub fn ServiceConf::from_json(src : String) -> ServiceConf raise ConfigError {
  let root = @json.parse(src) catch {
    err => raise ConfigError("invalid JSON: " + err.to_string())
  }
  let obj = match root {
    Object(m) => m
    _ => raise ConfigError("config root must be a JSON object")
  }
  service_conf_of_object(obj)
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
/// Raises `ConfigError` on malformed YAML, a non-mapping root, or a field of the
/// wrong type.
pub fn ServiceConf::from_yaml(src : String) -> ServiceConf raise ConfigError {
  let obj = match yaml_parse(src) {
    Object(m) => m
    _ => raise ConfigError("config root must be a YAML mapping")
  }
  service_conf_of_object(obj)
}

///|
/// Decode a `ServiceConf` from an already-parsed config object, filling every
/// omitted field from `ServiceConf::new()`'s defaults. Shared by the JSON and
/// YAML loaders so both formats apply identical lenient semantics.
fn service_conf_of_object(
  obj : Map[String, Json],
) -> ServiceConf raise ConfigError {
  let def = ServiceConf::new()
  let name = string_field(obj, "name", def.name)
  let host = string_field(obj, "host", def.host)
  let port = int_field(obj, "port", def.port)
  let timeout_ms = int_field(obj, "timeout_ms", def.timeout_ms)
  let log_level = match obj.get("log_level") {
    Some(String(s)) => LogLevel::parse(s)
    Some(_) => raise ConfigError("log_level must be a JSON string")
    None => def.log_level
  }
  { name, host, port, timeout_ms, log_level }
}

///|
/// Read a string field, falling back to `default` when absent; raises on a
/// present-but-non-string value.
fn string_field(
  obj : Map[String, Json],
  key : String,
  default : String,
) -> String raise ConfigError {
  match obj.get(key) {
    Some(String(s)) => s
    Some(_) => raise ConfigError(key + " must be a JSON string")
    None => default
  }
}

///|
/// Read an integer field, falling back to `default` when absent; raises on a
/// present-but-non-number value. JSON numbers are truncated to `Int`.
fn int_field(
  obj : Map[String, Json],
  key : String,
  default : Int,
) -> Int raise ConfigError {
  match obj.get(key) {
    Some(Number(n, ..)) => n.to_int()
    Some(_) => raise ConfigError(key + " must be a JSON number")
    None => default
  }
}
