///|
/// One extra key/value on a log entry (← `logx.LogField`). Fields are rendered
/// alongside the message inside the same JSON object, so a collector can index
/// them without parsing the message text.
pub(all) struct LogField {
  key : String
  value : Json
}

///|
/// Build a log field.
pub fn LogField::new(key : String, value : Json) -> LogField {
  { key, value, }
}

///|
/// Build a string-valued log field.
pub fn LogField::str(key : String, value : String) -> LogField {
  { key, value: Json::string(value), }
}

///|
/// Build a number-valued log field.
pub fn LogField::num(key : String, value : Double) -> LogField {
  { key, value: Json::number(value), }
}

///|
/// The bits of a logger that are shared by every view derived from it, so
/// `set_level` on the process logger is seen by a `with_duration` view taken
/// before it (← logx's package-level level and writer).
struct LogState {
  mut level : LogLevel
  mut writer : (String) -> Unit
}

///|
/// A leveled, structured logger (← go-zero's `logx`): entries below the
/// configured level are dropped without being rendered, and everything else is
/// written as one JSON object per line carrying `@timestamp`, `level`, `content`,
/// an optional `duration`, and any extra fields.
///
/// The timestamp is milliseconds from the injected `Clock`, not a formatted
/// calendar time: MoonBit has no portable date formatter, and the clock is
/// already how every other timed layer here reads the time.
pub struct Logger {
  state : LogState
  clock : Clock
  duration_ms : Int64?
}

///|
/// A logger writing to `writer` (`println` by default) at `level` and above.
pub fn Logger::new(
  clock : Clock,
  level? : LogLevel = Info,
  writer? : (String) -> Unit = line => println(line),
) -> Logger {
  { state: { level, writer, }, clock, duration_ms: None, }
}

///|
/// The level below which entries are dropped.
pub fn Logger::level(self : Logger) -> LogLevel {
  self.state.level
}

///|
/// Raise or lower the threshold (← `logx.SetLevel`), for this logger and every
/// view derived from it.
pub fn Logger::set_level(self : Logger, level : LogLevel) -> Unit {
  self.state.level = level
}

///|
/// Send entries somewhere other than stdout (← `logx.SetWriter`) — a file sink,
/// a buffer under test, a collector client.
pub fn Logger::set_writer(self : Logger, writer : (String) -> Unit) -> Unit {
  self.state.writer = writer
}

///|
/// Whether an entry at `level` would be written.
pub fn Logger::enabled(self : Logger, level : LogLevel) -> Bool {
  level >= self.state.level
}

///|
/// A view of this logger that stamps `duration` on every entry (←
/// `logx.WithDuration`), sharing the level and writer with the original.
pub fn Logger::with_duration(self : Logger, ms : Int64) -> Logger {
  { state: self.state, clock: self.clock, duration_ms: Some(ms), }
}

///|
/// Render and write one entry, unless `level` is below the threshold.
pub fn Logger::log(
  self : Logger,
  level : LogLevel,
  content : String,
  fields? : Array[LogField] = [],
) -> Unit {
  if !self.enabled(level) {
    return
  }
  let entry : Map[String, Json] = Map([
    ("@timestamp", Json::number(self.clock.now().to_double())),
    ("level", Json::string(level.to_string())),
    ("content", Json::string(content)),
  ])
  match self.duration_ms {
    Some(ms) => entry["duration"] = Json::number(ms.to_double())
    None => ()
  }
  for f in fields {
    entry[f.key] = f.value
  }
  (self.state.writer)(Json::object(entry).stringify())
}

///|
/// Write a `debug` entry.
pub fn Logger::debug(
  self : Logger,
  content : String,
  fields? : Array[LogField] = [],
) -> Unit {
  self.log(Debug, content, fields~)
}

///|
/// Write an `info` entry.
pub fn Logger::info(
  self : Logger,
  content : String,
  fields? : Array[LogField] = [],
) -> Unit {
  self.log(Info, content, fields~)
}

///|
/// Write an `error` entry.
pub fn Logger::error(
  self : Logger,
  content : String,
  fields? : Array[LogField] = [],
) -> Unit {
  self.log(Error, content, fields~)
}

///|
/// Write a `severe` entry.
pub fn Logger::severe(
  self : Logger,
  content : String,
  fields? : Array[LogField] = [],
) -> Unit {
  self.log(Severe, content, fields~)
}

///|
/// The process-wide logger (← logx's package-level logger): what the middlewares
/// write to when no logger is handed to them, on the system clock at `info`.
/// `RestEngine::new` points its level at the loaded `Log.Level`.
pub let logx : Logger = Logger::new(Clock::system())

///|
/// Set the process logger's level (← `logx.SetLevel`).
pub fn set_log_level(level : LogLevel) -> Unit {
  logx.set_level(level)
}

///|
/// Send the process logger's entries to `writer` (← `logx.SetWriter`).
pub fn set_log_writer(writer : (String) -> Unit) -> Unit {
  logx.set_writer(writer)
}
