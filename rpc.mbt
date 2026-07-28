///|
/// zRPC server configuration (← go-zero's `zrpc.RpcServerConf`): the service
/// name, the address it listens on, and a per-call timeout in milliseconds
/// (`0` disables it). The registry/etcd fields of go-zero's conf are modelled by
/// the separate discovery layer; this is the transport-facing core.
pub(all) struct RpcServerConf {
  name : String
  host : String
  port : Int
  timeout_ms : Int
} derive(FromJson, Eq, Debug)

///|
/// Build an RPC server config with go-zero-style defaults (`0.0.0.0:8080`, 2s
/// timeout).
pub fn RpcServerConf::new(
  name? : String = "rpc",
  host? : String = "0.0.0.0",
  port? : Int = 8080,
  timeout_ms? : Int = 2000,
) -> RpcServerConf {
  { name, host, port, timeout_ms }
}

///|
/// Load an `RpcServerConf` from a JSON config string, filling omitted fields
/// from the `new()` defaults — the lenient loader matching go-zero's
/// `,optional`/`,default=` config tags.
pub fn RpcServerConf::from_json(
  src : String,
) -> RpcServerConf raise ConfigError {
  let root = @json.parse(src) catch {
    err => raise ConfigError("invalid JSON: " + err.to_string())
  }
  match root {
    Object(m) => rpc_conf_of_object(m)
    _ => raise ConfigError("rpc config root must be a JSON object")
  }
}

///|
/// Load an `RpcServerConf` from a YAML config string (self-built `yaml_parse`),
/// with the same default-filling semantics as `from_json`.
pub fn RpcServerConf::from_yaml(
  src : String,
) -> RpcServerConf raise ConfigError {
  match yaml_parse(src) {
    Object(m) => rpc_conf_of_object(m)
    _ => raise ConfigError("rpc config root must be a YAML mapping")
  }
}

///|
/// Decode an `RpcServerConf` from a parsed config object, filling omitted fields
/// from `RpcServerConf::new()`. Shared by the JSON and YAML loaders.
fn rpc_conf_of_object(
  obj : Map[String, Json],
) -> RpcServerConf raise ConfigError {
  let def = RpcServerConf::new()
  {
    name: string_field(obj, "name", def.name),
    host: string_field(obj, "host", def.host),
    port: int_field(obj, "port", def.port),
    timeout_ms: int_field(obj, "timeout_ms", def.timeout_ms),
  }
}

///|
/// A unary RPC handler: it maps a request message's wire bytes to a response
/// message's wire bytes (the `application/grpc+proto` payload, sans the
/// length-prefix framing that `@moonrpc.encode_message` adds). Streaming
/// handlers arrive with the h2 transport; this is the unary shape zRPC registers
/// today.
pub type RpcHandler = (Bytes) -> Bytes

///|
/// A server-streaming handler: one request message in, an ordered sequence of
/// response messages out (each framed as its own length-prefixed gRPC message).
/// Mirrors go-zero's `pb.XxxServer` server-streaming method, which writes to a
/// `grpc.ServerStream` instead of returning one reply.
pub type ServerStreamHandler = (Bytes) -> Array[Bytes]

///|
/// A client-streaming handler: every request message the client sends is
/// collected, and after the client half-closes the handler returns one reply.
pub type ClientStreamHandler = (Array[Bytes]) -> Bytes

///|
/// A zRPC server (← go-zero's `zrpc.Server`): config plus a registry mapping
/// each method's gRPC `:path` (`/package.Service/Method`) to its handler.
/// Handlers are registered via `@moonrpc.Method` descriptors — directly or
/// through a `RpcGroup` — and dispatched by path, mirroring how go-zero registers
/// service implementations on the underlying gRPC server. Unary, server-streaming,
/// and client-streaming methods live in separate registries so one path resolves
/// to exactly one cardinality.
pub struct RpcServer {
  conf : RpcServerConf
  handlers : Map[String, RpcHandler]
  server_streaming : Map[String, ServerStreamHandler]
  client_streaming : Map[String, ClientStreamHandler]
}

///|
/// Build an empty RPC server from its config.
pub fn RpcServer::new(conf : RpcServerConf) -> RpcServer {
  {
    conf,
    handlers: Map([]),
    server_streaming: Map([]),
    client_streaming: Map([]),
  }
}

///|
/// The server's configuration.
pub fn RpcServer::conf(self : RpcServer) -> RpcServerConf {
  self.conf
}

///|
/// Register `handler` for `method`, keyed by its gRPC path. A later
/// registration for the same path replaces the earlier one.
pub fn RpcServer::register(
  self : RpcServer,
  desc : @moonrpc.Method,
  handler : RpcHandler,
) -> Unit {
  self.handlers[desc.path()] = handler
}

///|
/// Register a server-streaming `handler` for `method`, keyed by its gRPC path.
pub fn RpcServer::register_server_streaming(
  self : RpcServer,
  desc : @moonrpc.Method,
  handler : ServerStreamHandler,
) -> Unit {
  self.server_streaming[desc.path()] = handler
}

///|
/// Register a client-streaming `handler` for `method`, keyed by its gRPC path.
pub fn RpcServer::register_client_streaming(
  self : RpcServer,
  desc : @moonrpc.Method,
  handler : ClientStreamHandler,
) -> Unit {
  self.client_streaming[desc.path()] = handler
}

///|
/// Open a `RpcGroup` that registers methods under the fully-qualified
/// `package.Service` name — go-zero's per-service registration, without
/// repeating the service name on each method.
pub fn RpcServer::group(self : RpcServer, service : String) -> RpcGroup {
  { server: self, service }
}

///|
/// Look up the handler registered for a gRPC `:path`, or `None` if unregistered.
pub fn RpcServer::lookup(self : RpcServer, path : String) -> RpcHandler? {
  self.handlers.get(path)
}

///|
/// The gRPC paths of every registered method.
pub fn RpcServer::methods(self : RpcServer) -> Array[String] {
  self.handlers.keys().collect()
}

///|
/// Whether a handler is registered for `path`.
pub fn RpcServer::has_method(self : RpcServer, path : String) -> Bool {
  self.handlers.contains(path)
}

///|
/// Dispatch a unary call to the handler registered for `path`, returning the
/// response bytes. An unregistered path yields `Err(Unimplemented)` — exactly
/// the `grpc-status` a real gRPC server returns for an unknown method — so a
/// transport can translate the result straight onto the wire.
pub fn RpcServer::dispatch(
  self : RpcServer,
  path : String,
  request : Bytes,
) -> Result[Bytes, @moonrpc.Status] {
  match self.handlers.get(path) {
    Some(handler) => Ok(handler(request))
    None => Err(@moonrpc.Status::Unimplemented)
  }
}

///|
/// A per-service registration handle (← go-zero's service registrar closure):
/// binds a set of methods to one `package.Service` on a shared `RpcServer`.
pub struct RpcGroup {
  server : RpcServer
  service : String
}

///|
/// The fully-qualified `package.Service` this group registers under.
pub fn RpcGroup::service(self : RpcGroup) -> String {
  self.service
}

///|
/// Register a method `name` on this group's service, building the
/// `@moonrpc.Method` descriptor and installing `handler` under its gRPC path.
/// (`register`, not `method` — the latter is a reserved word.)
pub fn RpcGroup::register(
  self : RpcGroup,
  name : String,
  handler : RpcHandler,
) -> Unit {
  self.server.register({ service: self.service, name }, handler)
}

///|
/// Register a server-streaming method `name` on this group's service.
pub fn RpcGroup::register_server_streaming(
  self : RpcGroup,
  name : String,
  handler : ServerStreamHandler,
) -> Unit {
  self.server.register_server_streaming(
    { service: self.service, name },
    handler,
  )
}

///|
/// Register a client-streaming method `name` on this group's service.
pub fn RpcGroup::register_client_streaming(
  self : RpcGroup,
  name : String,
  handler : ClientStreamHandler,
) -> Unit {
  self.server.register_client_streaming(
    { service: self.service, name },
    handler,
  )
}
