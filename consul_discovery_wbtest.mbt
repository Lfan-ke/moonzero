// A stateful in-memory fake consul agent (a Map-backed service catalog driven by the
// real HTTP paths and JSON bodies) so the discovery driver's register -> pass-check ->
// resolve -> deregister flow round-trips through an actual agent on every backend. The
// same ConsulDiscovery drives a real consul over an HTTP socket in the native driver.

///|
/// One registered service instance in the fake agent. `healthy` flips true only once
/// its TTL check has been passed, mirroring consul starting a fresh TTL check critical.
struct ConsulInstance {
  name : String
  address : String
  port : Int
  mut healthy : Bool
}

///|
/// A fake consul agent backing register / check-pass / deregister / health / services
/// with a Map keyed by instance id — enough to exercise the discovery driver.
struct FakeConsul {
  services : Map[String, ConsulInstance]
}

///|
fn FakeConsul::new() -> FakeConsul {
  { services: Map([]), }
}

///|
impl ConsulHttp for FakeConsul with fn request(self, verb, path, body) {
  if verb == "PUT" && path == "/v1/agent/service/register" {
    let json = @json.parse(@utf8.decode_lossy(body[:])) catch {
      _ => return ConsulResponse::new(400, b"bad json")
    }
    let id = consul_str_field(json, "ID")
    self.services[id] = {
      name: consul_str_field(json, "Name"),
      address: consul_str_field(json, "Address"),
      port: consul_int_field(json, "Port"),
      healthy: false,
    }
    return ConsulResponse::new(200, b"")
  }
  if verb == "PUT" && str_has_prefix(path, "/v1/agent/check/pass/") {
    // The check id is `service:<instance-id>`.
    let check_id = str_after(path, "/v1/agent/check/pass/")
    let id = str_after(check_id, "service:")
    match self.services.get(id) {
      Some(inst) => {
        inst.healthy = true
        return ConsulResponse::new(200, b"")
      }
      None => return ConsulResponse::new(404, b"unknown check")
    }
  }
  if verb == "PUT" && str_has_prefix(path, "/v1/agent/service/deregister/") {
    let id = str_after(path, "/v1/agent/service/deregister/")
    self.services.remove(id)
    return ConsulResponse::new(200, b"")
  }
  if verb == "GET" && str_has_prefix(path, "/v1/health/service/") {
    let rest = str_after(path, "/v1/health/service/")
    let name = str_before_char(rest, '?')
    let arr : Array[Json] = []
    for _id, inst in self.services {
      if inst.name == name && inst.healthy {
        let svc : Map[String, Json] = Map([
          ("Address", inst.address.to_json()),
          ("Port", inst.port.to_json()),
        ])
        let node : Map[String, Json] = Map([("Address", inst.address.to_json())])
        arr.push(
          Map([("Service", svc.to_json()), ("Node", node.to_json())]).to_json(),
        )
      }
    }
    return ConsulResponse::new(200, @utf8.encode(arr.to_json().stringify()))
  }
  if verb == "GET" && path == "/v1/agent/services" {
    let obj : Map[String, Json] = Map([])
    for id, inst in self.services {
      obj[id] = Map([
        ("ID", id.to_json()),
        ("Service", inst.name.to_json()),
        ("Address", inst.address.to_json()),
        ("Port", inst.port.to_json()),
      ]).to_json()
    }
    return ConsulResponse::new(200, @utf8.encode(obj.to_json().stringify()))
  }
  ConsulResponse::new(404, b"not found")
}

///|
/// Whether `s` starts with `p`.
fn str_has_prefix(s : String, p : String) -> Bool {
  if s.length() < p.length() {
    return false
  }
  for i = 0; i < p.length(); i = i + 1 {
    if s[i] != p[i] {
      return false
    }
  }
  true
}

///|
/// `s` with its leading `p` removed (or `s` unchanged if it does not start with `p`).
fn str_after(s : String, p : String) -> String {
  if str_has_prefix(s, p) {
    s[p.length():s.length()].to_owned()
  } else {
    s
  }
}

///|
/// The part of `s` before the first `c` (or all of `s` if `c` is absent).
fn str_before_char(s : String, c : Char) -> String {
  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == c.to_int() {
      return s[0:i].to_owned()
    }
  }
  s
}

///|
test "consul discovery: register, pass check, resolve healthy, deregister" {
  let disc = ConsulDiscovery::new(ConsulClient::new(FakeConsul::new()))
  // register passes the TTL check, so both instances resolve as healthy.
  let _ = disc.register("greeter", Endpoint::new("10.0.0.1", 9090))
  let _ = disc.register("greeter", Endpoint::new("10.0.0.2", 9090))
  let eps = disc.resolve("greeter")
  assert_eq(eps.length(), 2)
  let addrs = eps.map(e => e.address())
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // An unregistered service resolves to nothing.
  assert_eq(disc.resolve("other").length(), 0)
  // A different service registered on the same agent does not bleed in.
  let _ = disc.register("greet", Endpoint::new("10.0.0.9", 7000))
  assert_eq(disc.resolve("greeter").length(), 2)
  assert_eq(disc.resolve("greet").length(), 1)
  // The Resolve interface value the balancer consumes sees the same set.
  assert_eq(disc.resolver()("greeter").length(), 2)
  // Deregister one instance, then the whole service.
  disc.deregister_instance("greeter", Endpoint::new("10.0.0.1", 9090))
  assert_eq(disc.resolve("greeter").length(), 1)
  disc.deregister("greeter")
  assert_eq(disc.resolve("greeter").length(), 0)
  // `greet` was untouched by clearing `greeter`.
  assert_eq(disc.resolve("greet").length(), 1)
}

///|
test "consul client: a critical (unpassed) instance is not resolved until its check passes" {
  let fake = FakeConsul::new()
  let client = ConsulClient::new(fake)
  // Registered but check never passed -> critical -> filtered out of the healthy set.
  client.register_service("x-1.2.3.4-5000", "x", "1.2.3.4", 5000, 10)
  assert_eq(client.health_service("x").length(), 0)
  // Passing the check makes it healthy.
  client.check_pass("x-1.2.3.4-5000")
  let eps = client.health_service("x")
  assert_eq(eps.length(), 1)
  assert_eq(eps[0].address(), "1.2.3.4:5000")
}
