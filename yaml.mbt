///|
/// A logical, significant YAML line: its indentation (leading-space count) and
/// its content with the indentation and any trailing `# comment` removed. Blank
/// and comment-only lines are dropped during tokenisation, so every `YamlLine`
/// carries structure.
priv struct YamlLine {
  indent : Int
  text : String
}

///|
/// Whether `c` is an ASCII space or tab.
fn is_space(c : Int) -> Bool {
  c == ' '.to_int() || c == '\t'.to_int()
}

///|
/// Strip leading and trailing ASCII whitespace from `s`.
fn yaml_trim(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end && is_space(s[start].to_int()) {
    start = start + 1
  }
  while end > start && is_space(s[end - 1].to_int()) {
    end = end - 1
  }
  s[start:end].to_owned()
}

///|
/// Remove an unquoted trailing comment: a `#` at the start of the content or
/// preceded by whitespace begins a comment. A `#` inside a quoted scalar or
/// glued to a non-space character is kept (minimal-subset rule, documented on
/// `yaml_parse`).
fn strip_comment(s : String) -> String {
  let mut quote = 0
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    if quote != 0 {
      if c == quote {
        quote = 0
      }
    } else if c == '"'.to_int() || c == '\''.to_int() {
      quote = c
    } else if c == '#'.to_int() && (i == 0 || is_space(s[i - 1].to_int())) {
      return s[0:i].to_owned()
    }
  }
  s
}

///|
/// Split raw source into significant `YamlLine`s: strip comments, drop blank
/// lines, and record each surviving line's indentation.
fn yaml_tokenize(src : String) -> Array[YamlLine] {
  let out : Array[YamlLine] = []
  let sb = StringBuilder::new()
  let raw : Array[String] = []
  for i = 0; i < src.length(); i = i + 1 {
    let c = src[i].to_int()
    if c == '\n'.to_int() {
      raw.push(sb.to_string())
      sb.reset()
    } else if c != '\r'.to_int() {
      sb.write_char(src[i].unsafe_to_char())
    }
  }
  raw.push(sb.to_string())
  for line in raw {
    let mut indent = 0
    while indent < line.length() && line[indent].to_int() == ' '.to_int() {
      indent = indent + 1
    }
    let content = yaml_trim(strip_comment(line[indent:].to_owned()))
    if content.length() > 0 {
      out.push({ indent, text: content })
    }
  }
  out
}

///|
/// Whether `s` begins a block sequence item (`-` alone or `- ...`).
fn is_seq_item(s : String) -> Bool {
  s.length() > 0 &&
  s[0].to_int() == '-'.to_int() &&
  (s.length() == 1 || is_space(s[1].to_int()))
}

///|
/// The index of the `:` separating a mapping key from its value: the first `:`
/// at end-of-line or followed by whitespace, outside quotes. `None` if the line
/// is not a mapping entry.
fn key_sep(s : String) -> Int? {
  let mut quote = 0
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    if quote != 0 {
      if c == quote {
        quote = 0
      }
    } else if c == '"'.to_int() || c == '\''.to_int() {
      quote = c
    } else if c == ':'.to_int() &&
      (i + 1 == s.length() || is_space(s[i + 1].to_int())) {
      return Some(i)
    }
  }
  None
}

///|
/// Parse a scalar token to JSON: quoted strings verbatim, `~`/`null`/empty to
/// null, `true`/`false` to booleans, integer/float literals to numbers, and
/// anything else to a plain string.
fn yaml_scalar(raw : String) -> Json {
  let s = yaml_trim(raw)
  if s.length() == 0 || s == "~" || s == "null" {
    return Json::null()
  }
  if s == "true" {
    return Json::boolean(true)
  }
  if s == "false" {
    return Json::boolean(false)
  }
  let first = s[0].to_int()
  if (first == '"'.to_int() || first == '\''.to_int()) &&
    s.length() >= 2 &&
    s[s.length() - 1].to_int() == first {
    return Json::string(s[1:s.length() - 1].to_owned())
  }
  match parse_number(s) {
    Some(n) => Json::number(n)
    None => Json::string(s)
  }
}

///|
/// Parse a decimal integer or float literal (optional leading `-`, optional
/// single `.`) to a `Double`; `None` for anything that is not wholly numeric, so
/// `yaml_scalar` falls back to a string. Hand-written: core's `strconv` is not
/// imported here and YAML's numeric grammar is this narrow subset.
fn parse_number(s : String) -> Double? {
  if s.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if s[0].to_int() == '-'.to_int() {
    neg = true
    i = 1
  }
  if i >= s.length() {
    return None
  }
  let mut int_part = 0.0
  let mut seen_digit = false
  while i < s.length() &&
        s[i].to_int() >= '0'.to_int() &&
        s[i].to_int() <= '9'.to_int() {
    int_part = int_part * 10.0 + (s[i].to_int() - '0'.to_int()).to_double()
    seen_digit = true
    i = i + 1
  }
  let mut value = int_part
  if i < s.length() && s[i].to_int() == '.'.to_int() {
    i = i + 1
    let mut frac = 0.0
    let mut scale = 1.0
    while i < s.length() &&
          s[i].to_int() >= '0'.to_int() &&
          s[i].to_int() <= '9'.to_int() {
      frac = frac * 10.0 + (s[i].to_int() - '0'.to_int()).to_double()
      scale = scale * 10.0
      seen_digit = true
      i = i + 1
    }
    value = value + frac / scale
  }
  if !seen_digit || i != s.length() {
    return None
  }
  Some(if neg { -value } else { value })
}

///|
/// Parse a mapping at indentation `ind`, consuming consecutive entries at that
/// level (a value-less `key:` opens a nested block at deeper indent). `cur`
/// tracks the cursor into `lines`.
fn yaml_mapping(
  lines : Array[YamlLine],
  cur : Ref[Int],
  ind : Int,
) -> Json raise ConfigError {
  let m : Map[String, Json] = Map([])
  while cur.val < lines.length() &&
        lines[cur.val].indent == ind &&
        !is_seq_item(lines[cur.val].text) {
    let line = lines[cur.val]
    let sep = match key_sep(line.text) {
      Some(p) => p
      None => raise ConfigError("YAML: expected 'key: value', got " + line.text)
    }
    let key = unquote_key(yaml_trim(line.text[0:sep].to_owned()))
    let rest = yaml_trim(line.text[sep + 1:].to_owned())
    cur.val = cur.val + 1
    if rest.length() == 0 {
      m[key] = yaml_block(lines, cur, ind)
    } else {
      m[key] = yaml_scalar(rest)
    }
  }
  Json::object(m)
}

///|
/// Strip surrounding quotes from a mapping key, if present.
fn unquote_key(s : String) -> String {
  if s.length() >= 2 {
    let q = s[0].to_int()
    if (q == '"'.to_int() || q == '\''.to_int()) &&
      s[s.length() - 1].to_int() == q {
      return s[1:s.length() - 1].to_owned()
    }
  }
  s
}

///|
/// Parse a sequence at indentation `ind`, consuming consecutive `-` items. An
/// item may be a scalar, a nested block, or an inline mapping (`- key: value`,
/// possibly extended by aligned continuation lines).
fn yaml_sequence(
  lines : Array[YamlLine],
  cur : Ref[Int],
  ind : Int,
) -> Json raise ConfigError {
  let arr : Array[Json] = []
  while cur.val < lines.length() &&
        lines[cur.val].indent == ind &&
        is_seq_item(lines[cur.val].text) {
    let text = lines[cur.val].text
    // content after the leading '-', and the column that content starts at
    let mut j = 1
    while j < text.length() && is_space(text[j].to_int()) {
      j = j + 1
    }
    let content = text[j:].to_owned()
    let key_col = ind + j
    if content.length() == 0 {
      cur.val = cur.val + 1
      arr.push(yaml_block(lines, cur, ind + 1))
    } else if key_sep(content) is Some(_) {
      // rewrite this line as a mapping entry at the key column, then fold in
      // any aligned continuation lines belonging to the same item
      lines[cur.val] = { indent: key_col, text: content }
      arr.push(yaml_mapping(lines, cur, key_col))
    } else {
      cur.val = cur.val + 1
      arr.push(yaml_scalar(content))
    }
  }
  Json::array(arr)
}

///|
/// Parse the block starting at the cursor: dispatch to a sequence, a mapping, or
/// (for a lone deeper-indented scalar) a scalar, using the first line's shape.
fn yaml_block(
  lines : Array[YamlLine],
  cur : Ref[Int],
  parent_ind : Int,
) -> Json raise ConfigError {
  if cur.val >= lines.length() || lines[cur.val].indent <= parent_ind {
    return Json::null()
  }
  let ind = lines[cur.val].indent
  if is_seq_item(lines[cur.val].text) {
    yaml_sequence(lines, cur, ind)
  } else if key_sep(lines[cur.val].text) is Some(_) {
    yaml_mapping(lines, cur, ind)
  } else {
    let v = yaml_scalar(lines[cur.val].text)
    cur.val = cur.val + 1
    v
  }
}

///|
/// Parse a **minimal YAML subset** into a `Json` value: block mappings
/// (`key: value`), arbitrary indentation-based nesting, block sequences (`-
/// item`, including `- key: value` maps in a list), scalars (quoted/plain
/// strings, integers, floats, `true`/`false`, `~`/`null`), and `#` line
/// comments. Enough of YAML 1.1 to load go-zero-style service config. Flow style
/// (`{a: 1}`, `[1, 2]`), anchors/aliases, multi-document streams, and block
/// scalars (`|`/`>`) are **not** supported — use JSON for those. Raises
/// `ConfigError` on a line that is neither a mapping entry nor a sequence item.
pub fn yaml_parse(src : String) -> Json raise ConfigError {
  let lines = yaml_tokenize(src)
  if lines.length() == 0 {
    return Json::object(Map([]))
  }
  let cur : Ref[Int] = { val: 0 }
  let root_ind = lines[0].indent
  let doc = if is_seq_item(lines[0].text) {
    yaml_sequence(lines, cur, root_ind)
  } else if key_sep(lines[0].text) is Some(_) {
    yaml_mapping(lines, cur, root_ind)
  } else {
    let v = yaml_scalar(lines[0].text)
    cur.val = cur.val + 1
    v
  }
  if cur.val != lines.length() {
    raise ConfigError("YAML: unexpected line " + lines[cur.val].text)
  }
  doc
}
