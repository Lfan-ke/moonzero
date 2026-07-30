// A consul client over consul's HTTP API: a `ConsulHttp` carries a request to a consul
// agent and hands back the status and body, and `ConsulClient` wraps it with the agent
// operations the discovery driver needs (register a service with a TTL check, pass the
// check to keep it alive, deregister it, and read a service's healthy instances). The
// transport is an interface, so the same client drives a real consul over an HTTP
// socket (the native `discov` driver) or an in-process fake in a test; the request
// shaping and JSON parsing here run on every backend.

///|
/// A consul API call that failed — a transport error, or a non-2xx agent response.
pub suberror ConsulError {
  ConsulError(String)
}

///|
/// A consul agent's HTTP response: the status code and the raw body bytes.
pub struct ConsulResponse {
  status : Int
  body : Bytes
}

///|
/// A consul response.
pub fn ConsulResponse::new(status : Int, body : Bytes) -> ConsulResponse {
  { status, body }
}

///|
/// The HTTP status code.
pub fn ConsulResponse::status(self : ConsulResponse) -> Int {
  self.status
}

///|
/// The raw response body bytes.
pub fn ConsulResponse::body(self : ConsulResponse) -> Bytes {
  self.body
}

///|
/// A transport to a consul agent: it performs one HTTP request (`method` and `path`,
/// with `body` for writes) and returns the response. Implementations own the medium —
/// a real HTTP socket, or an in-memory fake.
pub trait ConsulHttp {
  fn request(Self, String, String, Bytes) -> ConsulResponse raise
}

///|
/// A consul client over a `ConsulHttp`, exposing the agent operations discovery uses.
pub struct ConsulClient {
  http : &ConsulHttp
}

///|
/// A client over `http`.
pub fn ConsulClient::new(http : &ConsulHttp) -> ConsulClient {
  { http, }
}

///|
/// Perform a request and require a 2xx status, mapping a transport failure or a non-2xx
/// response to `ConsulError`.
fn ConsulClient::call(
  self : ConsulClient,
  verb : String,
  path : String,
  body : Bytes,
) -> ConsulResponse raise ConsulError {
  let resp = self.http.request(verb, path, body) catch {
    e => raise ConsulError("consul transport error: " + e.to_string())
  }
  if resp.status < 200 || resp.status >= 300 {
    raise ConsulError(
      verb +
      " " +
      path +
      " -> HTTP " +
      resp.status.to_string() +
      ": " +
      @utf8.decode_lossy(resp.body[:]),
    )
  }
  resp
}

///|
/// The check id consul assigns an inline service TTL check: `service:<service-id>`.
pub fn consul_check_id(service_id : String) -> String {
  "service:" + service_id
}

///|
/// `PUT /v1/agent/service/register`: register an instance under `name` at
/// `address:port` with an id, held alive by a TTL check that consul deregisters
/// `ttl*3` seconds after it stops passing. Pass the check with `check_pass` before each
/// TTL lapses to stay healthy.
pub fn ConsulClient::register_service(
  self : ConsulClient,
  id : String,
  name : String,
  address : String,
  port : Int,
  ttl_secs : Int,
) -> Unit raise ConsulError {
  let _ = self.call(
    "PUT",
    "/v1/agent/service/register",
    consul_register_body(id, name, address, port, ttl_secs),
  )
}

///|
/// The JSON body of a `service/register` request: the instance's id, name, address, and
/// port, plus a TTL check that consul deregisters `ttl*3` seconds after it stops
/// passing. Exposed so the native HTTP-socket path builds the exact same body.
pub fn consul_register_body(
  id : String,
  name : String,
  address : String,
  port : Int,
  ttl_secs : Int,
) -> Bytes {
  let check : Map[String, Json] = Map([
    ("TTL", (ttl_secs.to_string() + "s").to_json()),
    (
      "DeregisterCriticalServiceAfter",
      ((ttl_secs * 3).to_string() + "s").to_json(),
    ),
  ])
  let body : Map[String, Json] = Map([
    ("ID", id.to_json()),
    ("Name", name.to_json()),
    ("Address", address.to_json()),
    ("Port", port.to_json()),
    ("Check", check.to_json()),
  ])
  @utf8.encode(body.to_json().stringify())
}

///|
/// `PUT /v1/agent/check/pass/service:<id>`: mark an instance's TTL check passing, the
/// keep-alive that renews its lease.
pub fn ConsulClient::check_pass(
  self : ConsulClient,
  service_id : String,
) -> Unit raise ConsulError {
  let _ = self.call(
    "PUT",
    "/v1/agent/check/pass/" + consul_check_id(service_id),
    b"",
  )
}

///|
/// `PUT /v1/agent/service/deregister/<id>`: deregister one instance.
pub fn ConsulClient::deregister_service(
  self : ConsulClient,
  id : String,
) -> Unit raise ConsulError {
  let _ = self.call("PUT", "/v1/agent/service/deregister/" + id, b"")
}

///|
/// `GET /v1/health/service/<name>?passing=true`: the healthy instances of `name`, each
/// as its `Service.Address:Service.Port` endpoint (falling back to `Node.Address` when
/// the service advertises no address of its own, as consul's clients do).
pub fn ConsulClient::health_service(
  self : ConsulClient,
  name : String,
) -> Array[Endpoint] raise ConsulError {
  let resp = self.call(
    "GET",
    "/v1/health/service/" + name + "?passing=true",
    b"",
  )
  parse_health_response(resp.body)
}

///|
/// `GET /v1/agent/services`: every service instance registered on this agent, as
/// `(instance-id, service-name)` pairs — the list a by-name deregister filters to find
/// the ids to drop.
pub fn ConsulClient::agent_services(
  self : ConsulClient,
) -> Array[(String, String)] raise ConsulError {
  let resp = self.call("GET", "/v1/agent/services", b"")
  let text = @utf8.decode_lossy(resp.body[:])
  let json = @json.parse(text) catch {
    e => raise ConsulError("invalid consul JSON: " + e.to_string())
  }
  let obj = match json {
    Object(o) => o
    _ => raise ConsulError("consul agent/services is not a JSON object")
  }
  let out : Array[(String, String)] = []
  for _id, svc in obj {
    let id = consul_str_field(svc, "ID")
    let name = consul_str_field(svc, "Service")
    if id != "" {
      out.push((id, name))
    }
  }
  out
}

///|
/// Parse a consul `health/service` JSON body into endpoints — exposed so the native
/// HTTP-socket path decodes a real agent's response exactly as the client does.
pub fn consul_parse_health(body : Bytes) -> Array[Endpoint] raise ConsulError {
  parse_health_response(body)
}

///|
/// Parse a consul `health/service` JSON array into endpoints.
fn parse_health_response(body : Bytes) -> Array[Endpoint] raise ConsulError {
  let text = @utf8.decode_lossy(body[:])
  let json = @json.parse(text) catch {
    e => raise ConsulError("invalid consul JSON: " + e.to_string())
  }
  let entries = match json {
    Array(a) => a
    _ => raise ConsulError("consul health response is not a JSON array")
  }
  let out : Array[Endpoint] = []
  for entry in entries {
    let service = match json_field(entry, "Service") {
      Some(s) => s
      None => continue
    }
    let node_addr = match json_field(entry, "Node") {
      Some(n) => consul_str_field(n, "Address")
      None => ""
    }
    let svc_addr = consul_str_field(service, "Address")
    let address = if svc_addr == "" { node_addr } else { svc_addr }
    let port = consul_int_field(service, "Port")
    if address != "" && port > 0 {
      out.push(Endpoint::new(address, port))
    }
  }
  out
}

///|
/// The value of `key` in a JSON object, or `None` if `obj` is not an object or lacks
/// the key.
fn json_field(obj : Json, key : String) -> Json? {
  if obj is Object(m) {
    m.get(key)
  } else {
    None
  }
}

///|
/// The string value of `key` in a JSON object, or `""`.
fn consul_str_field(obj : Json, key : String) -> String {
  match json_field(obj, key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// The integer value of a JSON number `key`, truncated toward zero, or `0`.
fn consul_int_field(obj : Json, key : String) -> Int {
  match json_field(obj, key) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}
