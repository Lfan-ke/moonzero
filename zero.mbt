///|
/// Service configuration (← go-zero's `ServiceConf`): a name and a bind address.
pub(all) struct ServiceConf {
  name : String
  host : String
  port : Int
}

///|
/// Build a config with sensible defaults (`0.0.0.0:8888`).
pub fn ServiceConf::new(
  name? : String = "app",
  host? : String = "0.0.0.0",
  port? : Int = 8888,
) -> ServiceConf {
  { name, host, port }
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
  { conf, handler: app.to_asgi() }
}

///|
/// Wrap the current application in another middleware layer (outermost last).
pub fn Server::use_(self : Server, mw : Middleware) -> Server {
  { conf: self.conf, handler: mw(self.handler) }
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
/// A request-logging middleware: prints `METHOD path` for each HTTP request, then
/// delegates to the wrapped application.
pub fn logging(inner : @moonasgi.AsgiApp) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    match scope {
      Http(hs) => println(hs.http_method + " " + hs.path)
      _ => ()
    }
    inner(scope, receive, send)
  }
}
