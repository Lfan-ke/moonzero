///|
/// Log verbosity (← go-zero's `LogConf.Level`), ordered from most to least
/// verbose. `Compare` follows that order so thresholds can be tested directly.
pub(all) enum LogLevel {
  Debug
  Info
  Error
  Severe
} derive(Eq, Compare, Debug)

///|
/// The canonical lowercase name go-zero uses on the wire.
pub fn LogLevel::to_string(self : LogLevel) -> String {
  match self {
    Debug => "debug"
    Info => "info"
    Error => "error"
    Severe => "severe"
  }
}

///|
/// Parse a level name, falling back to `Info` for anything unrecognised — the
/// same lenient default go-zero applies to a missing/empty level.
pub fn LogLevel::parse(s : String) -> LogLevel {
  match s {
    "debug" => Debug
    "error" => Error
    "severe" => Severe
    _ => Info
  }
}

///|
/// Service configuration (← go-zero's `ServiceConf`): the service name, its bind
/// address, a request timeout, and the log level. `timeout_ms` is the per-request
/// budget in milliseconds; `0` disables the deadline.
pub(all) struct ServiceConf {
  name : String
  host : String
  port : Int
  timeout_ms : Int
  log_level : LogLevel
} derive(FromJson, Eq)

///|
/// Build a config with sensible defaults (`0.0.0.0:8888`, 3s timeout, `info`).
pub fn ServiceConf::new(
  name? : String = "app",
  host? : String = "0.0.0.0",
  port? : Int = 8888,
  timeout_ms? : Int = 3000,
  log_level? : LogLevel = Info,
) -> ServiceConf {
  { name, host, port, timeout_ms, log_level, }
}

///|
/// An AsgiApp transformer — one layer of the middleware onion.
pub type Middleware = (@moonasgi.AsgiApp) -> @moonasgi.AsgiApp

///|
/// A moonzero service: its config plus the assembled application (a moonapi App
/// with any middleware already wrapped around it).
pub struct Server {
  conf : ServiceConf
  handler : @moonasgi.AsgiApp
}

///|
/// Assemble a service from config and a moonapi application.
pub fn Server::new(conf : ServiceConf, app : @moonapi.App) -> Server {
  { conf, handler: app.to_asgi(), }
}

///|
/// Wrap the current application in another middleware layer (outermost last).
pub fn Server::use_(self : Server, mw : Middleware) -> Server {
  { conf: self.conf, handler: mw(self.handler), }
}

///|
/// The assembled `AsgiApp`, ready for a server (mooncat) to run.
pub fn Server::to_asgi(self : Server) -> @moonasgi.AsgiApp {
  self.handler
}

///|
/// A human-readable description of what this service binds to.
pub fn Server::describe(self : Server) -> String {
  self.conf.name +
  " listening on " +
  self.conf.host +
  ":" +
  self.conf.port.to_string()
}

///|
/// A request-logging middleware: writes `METHOD path` through the process `logx`
/// at `info` for each HTTP request, then delegates to the wrapped application.
/// It logs on the way in and knows nothing of the response; `structured_logging`
/// is the layer that times the request and records its status.
pub fn logging(inner : @moonasgi.AsgiApp) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    match scope {
      Http(hs) => logx.info(hs.http_method + " " + hs.path)
      _ => ()
    }
    inner(scope, receive, send)
  }
}
