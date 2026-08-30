///|
/// The resolve half of go-zero's discovery (← `discov.Discovery`): a function from a
/// service name to its live endpoints. Any store — the in-memory `InMemoryRegistry`,
/// the persisted `PersistentRegistry`, or a future etcd/consul client — exposes one
/// via `resolver()`, so a balancer and the load-balanced channel are written once
/// against the interface and the backing store swaps by swapping the closure.
pub type Resolve = (String) -> Array[Endpoint]

///|
/// This registry as a `Resolve` interface value.
pub fn InMemoryRegistry::resolver(self : InMemoryRegistry) -> Resolve {
  service => self.resolve(service)
}

///|
/// This registry as a `Resolve` interface value.
pub fn PersistentRegistry::resolver(self : PersistentRegistry) -> Resolve {
  service => self.resolve(service)
}

///|
/// A change to the registry keyspace, in etcd v3's watch shape: a `Put` carries the
/// instance key and its endpoint, a `Delete` carries the key that went away, and
/// both carry the store revision the change produced. A watcher receives these in
/// revision order, so a client can rebuild the live set incrementally instead of
/// re-resolving the whole service.
pub(all) enum RegistryEvent {
  Put(key~ : String, endpoint~ : Endpoint, revision~ : Int64)
  Delete(key~ : String, revision~ : Int64)
} derive(Eq, Debug)

///|
/// The store revision a registry event was produced at.
pub fn RegistryEvent::revision(self : RegistryEvent) -> Int64 {
  match self {
    Put(revision~, ..) => revision
    Delete(revision~, ..) => revision
  }
}

///|
/// A persisted, watchable service registry (← go-zero's etcd `discov` publisher):
/// the same two-level `service -> instance-id -> endpoint` store as
/// `InMemoryRegistry`, plus a per-key mod-revision, an append-only event log for
/// catch-up watchers, live watcher callbacks fired on every mutation, and
/// `snapshot`/`restore` that round-trip the whole keyspace through an etcd v3
/// `RangeResponse`-shaped JSON document — the bytes a file- or etcd-backed
/// deployment persists and reloads without losing a revision.
pub struct PersistentRegistry {
  instances : Map[String, Map[String, Endpoint]]
  key_rev : Map[String, Int64]
  mut seq : Int
  mut revision : Int64
  events : Array[RegistryEvent]
  watchers : Array[(RegistryEvent) -> Unit]
}

///|
/// A fresh, empty persisted registry at revision `0`.
pub fn PersistentRegistry::new() -> PersistentRegistry {
  {
    instances: Map([]),
    key_rev: Map([]),
    seq: 0,
    revision: 0,
    events: [],
    watchers: [],
  }
}

///|
/// The store revision, bumped on each register/deregister.
pub fn PersistentRegistry::revision(self : PersistentRegistry) -> Int64 {
  self.revision
}

///|
/// Notify live watchers and append to the catch-up log.
fn PersistentRegistry::emit(
  self : PersistentRegistry,
  event : RegistryEvent,
) -> Unit {
  self.events.push(event)
  for w in self.watchers {
    w(event)
  }
}

///|
/// Register `endpoint` under `service`, mint a fresh instance key, bump the
/// revision, and emit a `Put`. Returns the instance key (`<service>/<n>`).
pub fn PersistentRegistry::register(
  self : PersistentRegistry,
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
  self.key_rev[key] = self.revision
  self.emit(Put(key~, endpoint~, revision=self.revision))
  key
}

///|
/// Remove the instance at `key` from `service`. On success bumps the revision and
/// emits a `Delete`; an unknown service or key is a no-op returning `false`.
pub fn PersistentRegistry::deregister(
  self : PersistentRegistry,
  service : String,
  key : String,
) -> Bool {
  match self.instances.get(service) {
    Some(bucket) =>
      if bucket.contains(key) {
        bucket.remove(key)
        self.key_rev.remove(key)
        self.revision = self.revision + 1L
        self.emit(Delete(key~, revision=self.revision))
        true
      } else {
        false
      }
    None => false
  }
}

///|
/// The endpoints registered for `service`, in registration order.
pub fn PersistentRegistry::resolve(
  self : PersistentRegistry,
  service : String,
) -> Array[Endpoint] {
  match self.instances.get(service) {
    Some(bucket) => bucket.values().collect()
    None => []
  }
}

///|
/// Every service name with at least one live instance.
pub fn PersistentRegistry::services(self : PersistentRegistry) -> Array[String] {
  self.instances.keys().collect()
}

///|
/// Every registered instance as `(instance-key, endpoint, mod-revision)`, across
/// all services — the flat keyspace a file- or etcd-backed reader diffs one load
/// against the next to compute the `Put`/`Delete` events a change produced.
pub fn PersistentRegistry::keyed_entries(
  self : PersistentRegistry,
) -> Array[(String, Endpoint, Int64)] {
  let out : Array[(String, Endpoint, Int64)] = []
  for _service, bucket in self.instances {
    for key, ep in bucket {
      let rev = match self.key_rev.get(key) {
        Some(r) => r
        None => 0L
      }
      out.push((key, ep, rev))
    }
  }
  out
}

///|
/// Register a live watcher fired on every subsequent mutation, in revision order
/// (← etcd's `Watch` with no start revision). To also see changes already applied,
/// replay `events_since` first.
pub fn PersistentRegistry::watch(
  self : PersistentRegistry,
  on_event : (RegistryEvent) -> Unit,
) -> Unit {
  self.watchers.push(on_event)
}

///|
/// Every event with a revision greater than `revision` (← etcd's watch
/// `start_revision`): the catch-up a client replays to reach the current state
/// before switching to live `watch` callbacks.
pub fn PersistentRegistry::events_since(
  self : PersistentRegistry,
  revision : Int64,
) -> Array[RegistryEvent] {
  let out : Array[RegistryEvent] = []
  for e in self.events {
    if e.revision() > revision {
      out.push(e)
    }
  }
  out
}

///|
/// Serialize the whole keyspace as an etcd v3 `RangeResponse`-shaped JSON document:
/// a header carrying the store revision and the id counter, and one key/value entry
/// per instance carrying its endpoint and mod-revision. This is the exact payload a
/// file- or etcd-backed deployment persists; `restore` rebuilds an identical
/// registry from it, revisions intact.
pub fn PersistentRegistry::snapshot(self : PersistentRegistry) -> String {
  let kvs : Array[Json] = []
  for service, bucket in self.instances {
    for key, ep in bucket {
      let rev = match self.key_rev.get(key) {
        Some(r) => r
        None => 0L
      }
      let entry : Map[String, Json] = Map([
        ("key", key.to_json()),
        ("service", service.to_json()),
        ("host", ep.host.to_json()),
        ("port", ep.port.to_json()),
        ("weight", ep.weight.to_json()),
        ("mod_revision", rev.to_string().to_json()),
      ])
      kvs.push(entry.to_json())
    }
  }
  let header : Map[String, Json] = Map([
    ("revision", self.revision.to_string().to_json()),
    ("seq", self.seq.to_json()),
  ])
  let root : Map[String, Json] = Map([
    ("header", header.to_json()),
    ("kvs", kvs.to_json()),
  ])
  root.to_json().stringify(indent=2)
}

///|
/// Rebuild a registry from a `snapshot` document, preserving instance keys, their
/// endpoints and mod-revisions, the id counter, and the store revision — so a
/// reloaded registry mints the next key exactly where the persisted one left off
/// and a watcher's `events_since(old_revision)` still lines up.
pub fn PersistentRegistry::restore(
  src : String,
) -> PersistentRegistry raise ConfigError {
  let root = @json.parse(src) catch {
    err => raise ConfigError("invalid registry snapshot: " + err.to_string())
  }
  let obj = match root {
    Object(m) => m
    _ => raise ConfigError("registry snapshot root must be a JSON object")
  }
  let reg = PersistentRegistry::new()
  match obj.get("header") {
    Some(Object(h)) => {
      reg.revision = int64_field(h, "revision")
      reg.seq = int_field_json(h, "seq")
    }
    _ => ()
  }
  match obj.get("kvs") {
    Some(Array(kvs)) =>
      for kv in kvs {
        match kv {
          Object(e) => {
            let service = string_field_json(e, "service")
            let key = string_field_json(e, "key")
            let ep = Endpoint::new(
              string_field_json(e, "host"),
              int_field_json(e, "port"),
              weight=int_field_json(e, "weight"),
            )
            let bucket = match reg.instances.get(service) {
              Some(b) => b
              None => {
                let b : Map[String, Endpoint] = Map([])
                reg.instances[service] = b
                b
              }
            }
            bucket[key] = ep
            reg.key_rev[key] = int64_field(e, "mod_revision")
          }
          _ => ()
        }
      }
    _ => ()
  }
  reg
}

// -- snapshot field accessors ----------------------------------------------

///|
/// The string value of `field` in `obj`, or `""` if absent or not a string.
fn string_field_json(obj : Map[String, Json], field : String) -> String {
  match obj.get(field) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// The integer value of a JSON `Number` `field`, truncated toward zero, or `0`.
fn int_field_json(obj : Map[String, Json], field : String) -> Int {
  match obj.get(field) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}

///|
/// The `Int64` value of a decimal-string `field` (revisions are carried as strings
/// so no precision is lost), or `0`.
fn int64_field(obj : Map[String, Json], field : String) -> Int64 {
  match obj.get(field) {
    Some(String(s)) => int64_of_decimal(s)
    _ => 0L
  }
}

///|
/// Parse an unsigned decimal string as an `Int64`. Non-digit octets are skipped, so
/// a well-formed revision string parses exactly.
fn int64_of_decimal(s : String) -> Int64 {
  let mut n = 0L
  for i = 0; i < s.length(); i = i + 1 {
    let d = s[i].to_int() - 0x30
    if d >= 0 && d <= 9 {
      n = n * 10L + d.to_int64()
    }
  }
  n
}

// -- load-balanced client ---------------------------------------------------

///|
/// The choice of balancer for a load-balanced channel: round-robin cycles through
/// the resolved instances (spreading load evenly), `WeightedBalancer` shares them
/// out in proportion to `Endpoint::weight`, `PickFirst` pins the head instance
/// (← gRPC's `pick_first`).
pub(all) enum Balancer {
  RoundRobinBalancer(RoundRobin)
  PickFirst
  WeightedBalancer(WeightedRoundRobin)
}

///|
/// A round-robin balancer, cursor at the first instance.
pub fn Balancer::round_robin() -> Balancer {
  RoundRobinBalancer(RoundRobin::new())
}

///|
/// A weighted balancer, with no credit accrued yet.
pub fn Balancer::weighted() -> Balancer {
  WeightedBalancer(WeightedRoundRobin::new())
}

///|
/// Pick one endpoint from a resolved set, or `None` if it is empty.
pub fn Balancer::pick(
  self : Balancer,
  endpoints : Array[Endpoint],
) -> Endpoint? {
  match self {
    RoundRobinBalancer(rr) => rr.pick(endpoints)
    PickFirst => pick_first(endpoints)
    WeightedBalancer(wrr) => wrr.pick(endpoints)
  }
}

///|
/// The in-process dial table: an endpoint address maps to the `RpcServer` listening
/// there. It stands in for DNS resolution plus a socket dial in the in-process h2c
/// transport — a real deployment opens a connection to the address instead of
/// looking the server up here, but the resolve→balance→call path above it is the
/// same.
pub struct RpcCluster {
  servers : Map[String, RpcServer]
}

///|
/// An empty cluster.
pub fn RpcCluster::new() -> RpcCluster {
  { servers: Map([]), }
}

///|
/// Bind the server reachable at `endpoint`'s address.
pub fn RpcCluster::add(
  self : RpcCluster,
  endpoint : Endpoint,
  server : RpcServer,
) -> Unit {
  self.servers[endpoint.address()] = server
}

///|
/// Open a channel to the server bound at `endpoint`, or `None` if nothing is
/// reachable there (a stale registry entry pointing at a gone instance).
pub fn RpcCluster::dial(self : RpcCluster, endpoint : Endpoint) -> RpcChannel? {
  match self.servers.get(endpoint.address()) {
    Some(server) =>
      Some(RpcChannel::connect(server, authority=endpoint.address()))
    None => None
  }
}

///|
/// A load-balanced zRPC client (← go-zero's `zrpc.Client` over a discovery target):
/// it resolves a service through the `Resolver`, picks a live instance with the
/// `Balancer`, dials it on the `RpcCluster`, and makes the call. The whole
/// resolve→balance→dial→call path runs per call, so instances registering or
/// deregistering between calls take effect on the next one.
pub struct LoadBalancedChannel {
  resolve : Resolve
  cluster : RpcCluster
  balancer : Balancer
  service : String
}

///|
/// Build a load-balanced channel for `service` over a `Resolve` interface, dialing
/// through `cluster` with `balancer` (round-robin by default).
pub fn LoadBalancedChannel::new(
  resolve : Resolve,
  cluster : RpcCluster,
  service : String,
  balancer? : Balancer = Balancer::round_robin(),
) -> LoadBalancedChannel {
  { resolve, cluster, balancer, service, }
}

///|
/// Resolve the service, pick a live instance, and dial it — the shared prelude of
/// every load-balanced call. `Unavailable` when the service has no instances or the
/// picked one is unreachable, matching the `grpc-status` a real client surfaces when
/// no subchannel is ready.
fn LoadBalancedChannel::pick_channel(
  self : LoadBalancedChannel,
) -> Result[RpcChannel, @moonrpc.Status] {
  let endpoints = (self.resolve)(self.service)
  match self.balancer.pick(endpoints) {
    None => Err(@moonrpc.Status::Unavailable)
    Some(endpoint) =>
      match self.cluster.dial(endpoint) {
        Some(channel) => Ok(channel)
        None => Err(@moonrpc.Status::Unavailable)
      }
  }
}

///|
/// Make a unary call to `path`, resolving and balancing to a live instance first.
pub fn LoadBalancedChannel::call(
  self : LoadBalancedChannel,
  path : String,
  request : Bytes,
) -> Result[Bytes, @moonrpc.Status] raise {
  match self.pick_channel() {
    Ok(channel) => channel.call(path, request)
    Err(status) => Err(status)
  }
}

///|
/// Make a server-streaming call to `path`, resolving and balancing to a live
/// instance first.
pub fn LoadBalancedChannel::call_server_streaming(
  self : LoadBalancedChannel,
  path : String,
  request : Bytes,
) -> Result[Array[Bytes], @moonrpc.Status] raise {
  match self.pick_channel() {
    Ok(channel) => channel.call_server_streaming(path, request)
    Err(status) => Err(status)
  }
}

///|
/// Make a bidirectional-streaming call to `path`, resolving and balancing to a
/// live instance first, then driving the whole `requests` exchange to completion.
pub fn LoadBalancedChannel::call_bidi_streaming(
  self : LoadBalancedChannel,
  path : String,
  requests : Array[Bytes],
) -> Result[Array[Bytes], @moonrpc.Status] raise {
  match self.pick_channel() {
    Ok(channel) => channel.call_bidi_streaming(path, requests)
    Err(status) => Err(status)
  }
}
