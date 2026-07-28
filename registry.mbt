///|
/// A service endpoint (← go-zero's `discov` target): the host and port an
/// instance listens on, plus a routing weight the balancer honours (default `1`).
pub(all) struct Endpoint {
  host : String
  port : Int
  weight : Int
} derive(Eq, Debug)

///|
/// Build an endpoint; `weight` defaults to `1`, matching an unweighted instance.
pub fn Endpoint::new(host : String, port : Int, weight? : Int = 1) -> Endpoint {
  { host, port, weight }
}

///|
/// The `host:port` dial string.
pub fn Endpoint::address(self : Endpoint) -> String {
  self.host + ":" + self.port.to_string()
}

///|
/// An in-memory service registry (← go-zero's etcd `discov` store, minus the
/// network): a two-level map of `service -> instance-id -> endpoint` and a
/// monotonic revision bumped on every mutation, mirroring etcd's store revision
/// so a watcher could detect change. Instance ids are `<service>/<n>`, the leaf of
/// the etcd key an instance would lease.
pub struct InMemoryRegistry {
  instances : Map[String, Map[String, Endpoint]]
  mut seq : Int
  mut revision : Int64
}

///|
/// A fresh, empty registry at revision `0`.
pub fn InMemoryRegistry::new() -> InMemoryRegistry {
  { instances: Map([]), seq: 0, revision: 0 }
}

///|
/// The store revision, incremented on each register/deregister — etcd's
/// mod-revision, the value a watcher compares against to see new state.
pub fn InMemoryRegistry::revision(self : InMemoryRegistry) -> Int64 {
  self.revision
}

///|
/// Register `endpoint` under `service` and return its instance key. Each call
/// mints a distinct key, so two instances of one service coexist, and bumps the
/// revision.
pub fn InMemoryRegistry::register(
  self : InMemoryRegistry,
  service : String,
  endpoint : Endpoint,
) -> String {
  let bucket = match self.instances.get(service) {
    Some(b) => b
    None => {
      let b : Map[String, Endpoint] = Map([])
      self.instances[service] = b
      b
    }
  }
  self.seq = self.seq + 1
  let key = service + "/" + self.seq.to_string()
  bucket[key] = endpoint
  self.revision = self.revision + 1L
  key
}

///|
/// Remove the instance at `key` from `service`. Returns `true` if it existed (and
/// bumps the revision), `false` if the service or key was unknown.
pub fn InMemoryRegistry::deregister(
  self : InMemoryRegistry,
  service : String,
  key : String,
) -> Bool {
  match self.instances.get(service) {
    Some(bucket) =>
      if bucket.contains(key) {
        bucket.remove(key)
        self.revision = self.revision + 1L
        true
      } else {
        false
      }
    None => false
  }
}

///|
/// The endpoints registered for `service`, in registration order.
pub fn InMemoryRegistry::resolve(
  self : InMemoryRegistry,
  service : String,
) -> Array[Endpoint] {
  match self.instances.get(service) {
    Some(bucket) => bucket.values().collect()
    None => []
  }
}

///|
/// Every service name with at least one live instance.
pub fn InMemoryRegistry::services(self : InMemoryRegistry) -> Array[String] {
  self.instances.keys().collect()
}

///|
/// Resolve `service` on the registry and pick one endpoint with `balancer` — the
/// resolve-then-balance step a zRPC client runs before each call. An etcd- or
/// consul-backed registry with the same `resolve` shape drops in unchanged.
pub fn resolve_one(
  registry : InMemoryRegistry,
  service : String,
  balancer : RoundRobin,
) -> Endpoint? {
  balancer.pick(registry.resolve(service))
}

///|
/// A round-robin balancer (← go-zero's `roundRobinBalancer`) over a resolved
/// endpoint set: successive `pick`s cycle through the instances, spreading load
/// evenly. Holds only a cursor, so it is cheap to keep per client.
pub struct RoundRobin {
  mut cursor : Int
}

///|
/// A round-robin balancer starting at the first instance.
pub fn RoundRobin::new() -> RoundRobin {
  { cursor: 0 }
}

///|
/// Pick the next endpoint in rotation, or `None` if the set is empty. The cursor
/// advances modulo the set size, so it stays valid as instances come and go.
pub fn RoundRobin::pick(
  self : RoundRobin,
  endpoints : Array[Endpoint],
) -> Endpoint? {
  let n = endpoints.length()
  if n == 0 {
    return None
  }
  let idx = self.cursor % n
  self.cursor = (self.cursor + 1) % n
  Some(endpoints[idx])
}

///|
/// Pick the first endpoint (← gRPC's `pick_first`), or `None` if the set is
/// empty. A stable choice that only moves when the head instance goes away.
pub fn pick_first(endpoints : Array[Endpoint]) -> Endpoint? {
  if endpoints.length() == 0 {
    None
  } else {
    Some(endpoints[0])
  }
}
