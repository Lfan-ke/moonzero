// HTTP over a real TCP socket: a consul agent transport the discovery flow drives
// against a live consul. moonzero's root `ConsulHttp` is synchronous (so the driver and
// its mock run on every backend), but socket I/O is async, so the real transport is a
// separate native-only path here — it reuses the root's pure HTTP/1 codec
// (`http1_request` to frame the request, `http1_parse_response` to parse the reply) and
// only adds the async connect/send/receive. Native-only, because `moonbitlang/async`
// has no JS/Wasm backend.

///|
/// A consul agent reachable over HTTP at `host:port`. Each request opens a fresh
/// connection (HTTP/1.0 with `Connection: close`), the simplest correct model for the
/// agent's short JSON round trips.
pub struct ConsulSocket {
  host : String
  port : Int
}

///|
/// A transport to the consul agent at `host:port` (default port 8500).
pub fn ConsulSocket::new(host : String, port? : Int = 8500) -> ConsulSocket {
  { host, port, }
}

///|
/// Perform one HTTP request against the agent and return its status and body.
pub async fn ConsulSocket::request(
  self : ConsulSocket,
  verb : String,
  path : String,
  body : Bytes,
) -> @moonzero.ConsulResponse {
  let addr = @socket.Addr::resolve(self.host, port=self.port)
  let tcp = @socket.Tcp::connect(addr)
  let content_type = if body.length() > 0 { "application/json" } else { "" }
  let host_header = self.host + ":" + self.port.to_string()
  let request = @moonzero.http1_request(
    verb,
    path,
    host_header,
    body,
    content_type~,
  )
  // The socket has to close on every path, cancellation included — there is no fd
  // finalizer to reclaim it otherwise.
  defer tcp.close()
  (tcp : &@io.Writer).write(request)
  let raw = (tcp : &@io.Reader).read_all()
  let parsed = @moonzero.http1_parse_response(raw.binary())
  @moonzero.ConsulResponse::new(parsed.status(), parsed.body())
}
