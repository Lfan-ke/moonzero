// The redis-backed discovery driver: the same register -> resolve -> deregister flow
// as the etcd driver, expressed over redis commands. An instance registers by SETting
// a per-instance key with a TTL (the lease), a keep-alive refreshes that TTL, and a
// client resolves a service by SCANning its key prefix and reading each endpoint back.
// This is a second `Resolve` for the balancer and load-balanced channel, chosen by
// swapping the driver — the resolve→balance→call path above it is unchanged.

///|
/// A redis-backed service registry / resolver. Instances of one service live under
/// `<prefix><service>/`, one key per instance keyed by its dial address, so a `SCAN`
/// of that prefix returns them all.
pub struct RedisDiscovery {
  client : RedisClient
  prefix : String
  seen : Map[String, Array[Endpoint]]
}

///|
/// A redis discovery over `client`; keys live under `prefix` (default `"moonzero/"`).
pub fn RedisDiscovery::new(
  client : RedisClient,
  prefix? : String = "moonzero/",
) -> RedisDiscovery {
  { client, prefix, seen: Map([]), }
}

///|
/// The key prefix a service's instances live under: `<prefix><service>/`. Exposed so
/// the native RESP-socket path builds the exact same keys as the in-process driver.
pub fn redis_service_prefix(prefix : String, service : String) -> String {
  prefix + service + "/"
}

///|
/// The key one instance of `service` lives at: `<prefix><service>/<address>`.
pub fn redis_instance_key(
  prefix : String,
  service : String,
  endpoint : Endpoint,
) -> String {
  redis_service_prefix(prefix, service) + endpoint.address()
}

///|
/// The `SCAN MATCH` glob for every instance of `service`: `<prefix><service>/*`.
pub fn redis_service_pattern(prefix : String, service : String) -> String {
  redis_service_prefix(prefix, service) + "*"
}

///|
/// The key one instance of `service` lives at: `<prefix><service>/<address>`.
fn RedisDiscovery::instance_key(
  self : RedisDiscovery,
  service : String,
  endpoint : Endpoint,
) -> String {
  redis_instance_key(self.prefix, service, endpoint)
}

///|
/// Register `endpoint` for `service` with a `ttl`-second lease and return its instance
/// key. Renew it with `keepalive` before the TTL lapses to stay registered; let it
/// lapse and redis drops the key, deregistering the instance automatically.
pub async fn RedisDiscovery::register(
  self : RedisDiscovery,
  service : String,
  endpoint : Endpoint,
  ttl? : Int = 10,
) -> String {
  let key = self.instance_key(service, endpoint)
  self.client.set_ex(@utf8.encode(key), @utf8.encode(endpoint.address()), ttl)
  key
}

///|
/// Refresh an instance's lease, extending its key's expiry by `ttl` seconds. `false`
/// if the key had already lapsed (the instance must re-`register`).
pub async fn RedisDiscovery::keepalive(
  self : RedisDiscovery,
  service : String,
  endpoint : Endpoint,
  ttl? : Int = 10,
) -> Bool {
  self.client.expire(@utf8.encode(self.instance_key(service, endpoint)), ttl)
}

///|
/// Resolve `service` to its live endpoints: `SCAN` the service prefix and read each
/// instance's value as its `host:port` endpoint. Keys that lapse mid-scan and
/// malformed values are skipped. The answer is also kept as the service's last known
/// set, which is what `resolver` hands a balancer.
pub async fn RedisDiscovery::resolve(
  self : RedisDiscovery,
  service : String,
) -> Array[Endpoint] {
  let pattern = @utf8.encode(redis_service_pattern(self.prefix, service))
  let keys = self.client.scan_match(pattern, 100)
  let out : Array[Endpoint] = []
  for key in keys {
    match self.client.get(key) {
      Some(value) =>
        match parse_endpoint(@utf8.decode_lossy(value[:])) {
          Some(ep) => out.push(ep)
          None => ()
        }
      None => ()
    }
  }
  self.seen[service] = out
  out
}

///|
/// The endpoints the last `resolve` of `service` found, without going to redis.
pub fn RedisDiscovery::last(
  self : RedisDiscovery,
  service : String,
) -> Array[Endpoint] {
  match self.seen.get(service) {
    Some(eps) => eps
    None => []
  }
}

///|
/// Deregister one instance of `service` by deleting its key.
pub async fn RedisDiscovery::deregister_instance(
  self : RedisDiscovery,
  service : String,
  endpoint : Endpoint,
) -> Unit {
  let _ = self.client.del([@utf8.encode(self.instance_key(service, endpoint))])
}

///|
/// Deregister every instance of `service` (delete the whole service prefix).
pub async fn RedisDiscovery::deregister(
  self : RedisDiscovery,
  service : String,
) -> Unit {
  let pattern = @utf8.encode(redis_service_pattern(self.prefix, service))
  let keys = self.client.scan_match(pattern, 100)
  let _ = self.client.del(keys)
}

///|
/// This redis discovery as a `Resolve` interface value, so the balancer and the
/// load-balanced channel run against redis unchanged. `Resolve` is synchronous and a
/// SCAN over a socket is not, so the closure reads the set the last `resolve` of that
/// service found — the same arrangement `discov`'s file registry uses, where the async
/// reload and the synchronous resolve are separate steps. A service not resolved yet
/// balances over nothing.
pub fn RedisDiscovery::resolver(self : RedisDiscovery) -> Resolve {
  service => self.last(service)
}
