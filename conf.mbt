///|
/// go-zero's canonical form for a config key (← the `WithCanonicalKeyFunc` that
/// `conf.Load` installs): lowercased, with `_` and `-` dropped. Every lookup
/// compares on this form, so `MaxBytes`, `maxBytes`, `max_bytes` and `max-bytes`
/// all name one field — which is what lets a genuine go-zero `etc/*.yaml`, whose
/// keys are all PascalCase, load into a config instead of silently yielding
/// defaults.
pub fn canonical_key(key : String) -> String {
  let low = key.to_lower()
  let sb = StringBuilder()
  for i = 0; i < low.length(); i = i + 1 {
    let c = low[i].to_int()
    if c != '_'.to_int() && c != '-'.to_int() {
      sb.write_char(low[i].unsafe_to_char())
    }
  }
  sb.to_string()
}

///|
/// A loaded config document (← go-zero's `conf.Load`): a parsed mapping read
/// through canonical keys and dotted paths, with the `,env=NAME` override and the
/// `default=` / `options=` / `range=` constraints go-zero spells as struct tags.
///
/// A field that is absent and has no default is an error, and so is a value that
/// violates its `options=` or `range=` constraint — a bad value never degrades
/// into the default.
pub struct Conf {
  root : Map[String, Json]
}

///|
/// Load a document from JSON. Raises `ConfigError` on malformed JSON or a
/// non-object root.
pub fn Conf::of_json(src : String) -> Conf raise ConfigError {
  let root = @json.parse(src) catch {
    err => raise ConfigError("invalid JSON: " + err.to_string())
  }
  match root {
    Object(m) => { root: m, }
    _ => raise ConfigError("config root must be a JSON object")
  }
}

///|
/// Load a document from the YAML go-zero ships as `etc/*.yaml`. Raises
/// `ConfigError` on malformed YAML or a non-mapping root.
pub fn Conf::of_yaml(src : String) -> Conf raise ConfigError {
  match yaml_parse(src) {
    Object(m) => { root: m, }
    _ => raise ConfigError("config root must be a YAML mapping")
  }
}

///|
/// Split a dotted path into its segments. A key containing a literal `.` is
/// therefore unreachable; go-zero's own nested lookups have the same shape.
fn path_segments(path : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  for i = 0; i < path.length(); i = i + 1 {
    if path[i].to_int() == '.'.to_int() {
      out.push(sb.to_string())
      sb.reset()
    } else {
      sb.write_char(path[i].unsafe_to_char())
    }
  }
  out.push(sb.to_string())
  out
}

///|
/// The entry of `obj` whose key matches `seg` canonically.
fn entry_of(obj : Map[String, Json], seg : String) -> Json? {
  let want = canonical_key(seg)
  for k, v in obj {
    if canonical_key(k) == want {
      return Some(v)
    }
  }
  None
}

///|
/// The value at a dotted `path`, or `None` if any segment is missing or a
/// non-mapping is walked into.
pub fn Conf::at(self : Conf, path : String) -> Json? {
  let mut cur = Json::object(self.root)
  for seg in path_segments(path) {
    match cur {
      Object(m) =>
        match entry_of(m, seg) {
          Some(v) => cur = v
          None => return None
        }
      _ => return None
    }
  }
  Some(cur)
}

///|
/// The value at `path`, treating an explicit `null` as absent so `Host:` with no
/// value falls back to its default the way an omitted key does.
fn Conf::present(self : Conf, path : String) -> Json? {
  match self.at(path) {
    Some(Null) => None
    other => other
  }
}

///|
/// The raw value backing a field: a non-empty `env` variable first (go-zero's
/// `,env=`), then the path, then each alternative spelling in turn.
fn Conf::raw(
  self : Conf,
  path : String,
  also : Array[String],
  env : String?,
) -> Json? {
  match env {
    Some(name) =>
      match @env.get_env_var(name) {
        // go-zero ignores an env var that is set but empty
        Some(v) => if v.length() > 0 { return Some(Json::string(v)) }
        None => ()
      }
    None => ()
  }
  match self.present(path) {
    Some(v) => return Some(v)
    None => ()
  }
  for a in also {
    match self.present(a) {
      Some(v) => return Some(v)
      None => ()
    }
  }
  None
}

///|
/// The error go-zero reports for a field with no value and no `default=`.
fn missing(path : String) -> ConfigError {
  ConfigError("field " + path + " is not set")
}

///|
/// Check a decoded string against an `options=` list.
fn check_options(
  value : String,
  path : String,
  options : Array[String]?,
) -> Unit raise ConfigError {
  match options {
    None => ()
    Some(allowed) => {
      for o in allowed {
        if o == value {
          return
        }
      }
      raise ConfigError(
        "value \"" +
        value +
        "\" for field " +
        path +
        " is not defined in options",
      )
    }
  }
}

///|
/// A numeric bound and whether it is open (exclusive).
priv struct Bound {
  at : Double?
  open : Bool
}

///|
/// A parsed `range=` tag: go-zero's `[a:b]`, `(a:b)`, `[a:b)` and `(a:b]`, with
/// either end left empty for unbounded.
priv struct RangeSpec {
  low : Bound
  high : Bound
}

///|
/// Parse a `range=` tag body. Raises `ConfigError` on a spec that is not one of
/// go-zero's four bracket forms.
fn range_parse(spec : String) -> RangeSpec raise ConfigError {
  let bad = ConfigError("bad range spec " + spec)
  if spec.length() < 3 {
    raise bad
  }
  let open_low = match spec[0].to_int() {
    c if c == '['.to_int() => false
    c if c == '('.to_int() => true
    _ => raise bad
  }
  let open_high = match spec[spec.length() - 1].to_int() {
    c if c == ']'.to_int() => false
    c if c == ')'.to_int() => true
    _ => raise bad
  }
  let body = spec[1:spec.length() - 1].to_owned()
  let mut colon = -1
  for i = 0; i < body.length(); i = i + 1 {
    if body[i].to_int() == ':'.to_int() {
      colon = i
      break
    }
  }
  if colon < 0 {
    raise bad
  }
  let low_src = yaml_trim(body[0:colon].to_owned())
  let high_src = yaml_trim(body[colon + 1:].to_owned())
  let low = if low_src.length() == 0 {
    None
  } else {
    match parse_number(low_src) {
      Some(n) => Some(n)
      None => raise bad
    }
  }
  let high = if high_src.length() == 0 {
    None
  } else {
    match parse_number(high_src) {
      Some(n) => Some(n)
      None => raise bad
    }
  }
  { low: { at: low, open: open_low, }, high: { at: high, open: open_high, }, }
}

///|
/// Whether `v` falls inside the range.
fn RangeSpec::contains(self : RangeSpec, v : Double) -> Bool {
  let above = match self.low.at {
    None => true
    Some(l) => if self.low.open { v > l } else { v >= l }
  }
  let below = match self.high.at {
    None => true
    Some(h) => if self.high.open { v < h } else { v <= h }
  }
  above && below
}

///|
/// Check a decoded number against a `range=` tag.
fn check_range(
  value : Double,
  path : String,
  range : String?,
) -> Unit raise ConfigError {
  match range {
    None => ()
    Some(spec) =>
      if !range_parse(spec).contains(value) {
        raise ConfigError(
          "value " +
          value.to_string() +
          " for field " +
          path +
          " is out of range " +
          spec,
        )
      }
  }
}

///|
/// Coerce a config value to a number. A quoted scalar that reads as a number is
/// accepted, so `Port: "8888"` and an env override both decode.
fn as_number(v : Json, path : String) -> Double raise ConfigError {
  match v {
    Number(n, ..) => n
    String(s) =>
      match parse_number(s) {
        Some(n) => n
        None => raise ConfigError("field " + path + " must be a number")
      }
    _ => raise ConfigError("field " + path + " must be a number")
  }
}

///|
/// Read a string field, honouring `env=`, `default=` and `options=`.
pub fn Conf::string(
  self : Conf,
  path : String,
  default? : String,
  options? : Array[String],
  env? : String,
  also? : Array[String] = [],
) -> String raise ConfigError {
  let value = match self.raw(path, also, env) {
    Some(String(s)) => s
    Some(_) => raise ConfigError("field " + path + " must be a string")
    None =>
      match default {
        Some(d) => d
        None => raise missing(path)
      }
  }
  check_options(value, path, options)
  value
}

///|
/// Read an `Int` field, honouring `env=`, `default=` and `range=`. A fractional
/// value is truncated toward zero after the range check.
pub fn Conf::int(
  self : Conf,
  path : String,
  default? : Int,
  range? : String,
  env? : String,
  also? : Array[String] = [],
) -> Int raise ConfigError {
  let value = match self.raw(path, also, env) {
    Some(v) => as_number(v, path)
    None =>
      match default {
        Some(d) => d.to_double()
        None => raise missing(path)
      }
  }
  check_range(value, path, range)
  value.to_int()
}

///|
/// Read an `Int64` field, honouring `env=`, `default=` and `range=`.
pub fn Conf::int64(
  self : Conf,
  path : String,
  default? : Int64,
  range? : String,
  env? : String,
  also? : Array[String] = [],
) -> Int64 raise ConfigError {
  let value = match self.raw(path, also, env) {
    Some(v) => as_number(v, path)
    None =>
      match default {
        Some(d) => d.to_double()
        None => raise missing(path)
      }
  }
  check_range(value, path, range)
  value.to_int64()
}

///|
/// Read a `Bool` field, honouring `env=` and `default=`. `true`/`false` spelled
/// as a string decode too, which is how an env override arrives.
pub fn Conf::bool(
  self : Conf,
  path : String,
  default? : Bool,
  env? : String,
  also? : Array[String] = [],
) -> Bool raise ConfigError {
  match self.raw(path, also, env) {
    Some(True) => true
    Some(False) => false
    Some(String("true")) => true
    Some(String("false")) => false
    Some(_) => raise ConfigError("field " + path + " must be a boolean")
    None =>
      match default {
        Some(d) => d
        None => raise missing(path)
      }
  }
}

///|
/// Read a string-list field, honouring `env=` and `default=`. An env override is
/// comma-separated, since a shell variable carries one string.
pub fn Conf::strings(
  self : Conf,
  path : String,
  default? : Array[String],
  env? : String,
  also? : Array[String] = [],
) -> Array[String] raise ConfigError {
  match self.raw(path, also, env) {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => raise ConfigError("field " + path + " must be a list of strings")
        }
      }
      out
    }
    Some(String(s)) => split_commas(s)
    Some(_) => raise ConfigError("field " + path + " must be a list of strings")
    None =>
      match default {
        Some(d) => d
        None => raise missing(path)
      }
  }
}

///|
/// Split a comma-separated list, trimming each item and dropping empties.
fn split_commas(s : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  fn flush() {
    let item = yaml_trim(sb.to_string())
    if item.length() > 0 {
      out.push(item)
    }
    sb.reset()
  }

  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == ','.to_int() {
      flush()
    } else {
      sb.write_char(s[i].unsafe_to_char())
    }
  }
  flush()
  out
}

///|
/// The list of sub-documents at `path` — the shape a `[]Struct` config field
/// takes, each element read back through the same constraint-checked accessors.
/// An absent path is an empty list; a non-list, or a list holding anything but
/// mappings, is an error.
pub fn Conf::list(self : Conf, path : String) -> Array[Conf] raise ConfigError {
  match self.present(path) {
    None => []
    Some(Array(items)) => {
      let out : Array[Conf] = []
      for item in items {
        match item {
          Object(m) => out.push({ root: m, })
          _ =>
            raise ConfigError("field " + path + " must be a list of mappings")
        }
      }
      out
    }
    Some(_) =>
      raise ConfigError("field " + path + " must be a list of mappings")
  }
}
