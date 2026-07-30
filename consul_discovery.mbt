// The consul-backed discovery driver: the same register -> resolve -> deregister flow
// as the etcd and redis drivers, expressed over consul's agent API. An instance
// registers as a consul service with a TTL check (the lease), a keep-alive passes that
// check, and a client resolves a service to its healthy instances. This is a third
// `Resolve` for the balancer and load-balanced channel, chosen by swapping the driver.

///|
/// A consul-backed service registry / resolver over a `ConsulClient`. Each instance is
/// a consul service named `service`, uniquely identified per agent by its address.
pub struct ConsulDiscovery {
  client : ConsulClient
}

///|
/// A consul discovery over `client`.
pub fn ConsulDiscovery::new(client : ConsulClient) -> ConsulDiscovery {
  { client, }
}

///|
/// The per-agent-unique instance id for `endpoint` of `service`:
/// `<service>-<host>-<port>`.
fn consul_instance_id(service : String, endpoint : Endpoint) -> String {
  service + "-" + endpoint.host + "-" + endpoint.port.to_string()
}

///|
/// Register `endpoint` for `service` with a `ttl`-second TTL check and immediately pass
/// the check so the instance is healthy at once (a fresh TTL check starts critical).
/// Returns the instance id; renew it with `keepalive` before the TTL lapses.
pub fn ConsulDiscovery::register(
  self : ConsulDiscovery,
  service : String,
  endpoint : Endpoint,
  ttl? : Int = 10,
) -> String raise {
  let id = consul_instance_id(service, endpoint)
  self.client.register_service(id, service, endpoint.host, endpoint.port, ttl)
  self.client.check_pass(id)
  id
}

///|
/// Refresh an instance's lease by passing its TTL check.
pub fn ConsulDiscovery::keepalive(
  self : ConsulDiscovery,
  service : String,
  endpoint : Endpoint,
) -> Unit raise {
  self.client.check_pass(consul_instance_id(service, endpoint))
}

///|
/// Resolve `service` to its healthy endpoints.
pub fn ConsulDiscovery::resolve(
  self : ConsulDiscovery,
  service : String,
) -> Array[Endpoint] raise {
  self.client.health_service(service)
}

///|
/// Deregister one instance of `service`.
pub fn ConsulDiscovery::deregister_instance(
  self : ConsulDiscovery,
  service : String,
  endpoint : Endpoint,
) -> Unit raise {
  self.client.deregister_service(consul_instance_id(service, endpoint))
}

///|
/// Deregister every instance of `service` registered on this agent.
pub fn ConsulDiscovery::deregister(
  self : ConsulDiscovery,
  service : String,
) -> Unit raise {
  for pair in self.client.agent_services() {
    let (id, name) = pair
    if name == service {
      self.client.deregister_service(id)
    }
  }
}

///|
/// This consul discovery as a `Resolve` interface value, so the balancer and the
/// load-balanced channel run against consul unchanged. A resolve error surfaces as an
/// empty endpoint set, matching the other drivers.
pub fn ConsulDiscovery::resolver(self : ConsulDiscovery) -> Resolve {
  service => self.resolve(service) catch { _ => [] }
}
