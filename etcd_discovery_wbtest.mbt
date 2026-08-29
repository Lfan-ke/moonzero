// A stateful in-memory mock etcd (a Map-backed KV over the real gRPC methods) so the
// discovery driver's register -> resolve -> deregister flow round-trips through an
// actual store, not a fixed response. Runs over the in-process h2c channel on every
// backend; the same EtcdDiscovery drives a real etcd over a socket-backed channel.

///|
/// Byte-lexicographic `<` on two ASCII keys — etcd orders and ranges its keyspace by
/// byte, whereas MoonBit's `String::compare` is length-first (shortlex), so a mock
/// standing in for etcd's range must compare bytes to match a real server's scan.
fn etcd_key_lt(a : String, b : String) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i = 0; i < n; i = i + 1 {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return ca < cb
    }
  }
  a.length() < b.length()
}

///|
/// Whether `k` falls in etcd's `[start, end)` range: `end == ""` is a single-key get,
/// otherwise a half-open byte range (the shape a prefix scan produces).
fn etcd_in_range(k : String, start : String, end : String) -> Bool {
  !etcd_key_lt(k, start) && (end == "" || etcd_key_lt(k, end))
}

///|
/// A mock etcd server backing Put / Range / DeleteRange / LeaseGrant with a Map, so a
/// key put by one call is visible to a later Range — enough to exercise discovery.
fn stateful_etcd_server() -> RpcServer {
  let store : Map[String, String] = Map([])
  let next_lease = Ref(1000L)
  let server = RpcServer::new(RpcServerConf::new())
  let kv = server.group("etcdserverpb.KV")
  kv.register("Put", req => {
    try {
      let p = EtcdPutRequest::decode(req)
      store[@utf8.decode_lossy(p.key[:])] = @utf8.decode_lossy(p.value[:])
      EtcdPutResponse::{ prev_kv: EtcdKeyValue::empty(), }.encode()
    } catch {
      _ => b""
    }
  })
  kv.register("Range", req => {
    try {
      let rr = EtcdRangeRequest::decode(req)
      let start = @utf8.decode_lossy(rr.key[:])
      let end = @utf8.decode_lossy(rr.range_end[:])
      let kvs : Array[EtcdKeyValue] = []
      for k, v in store {
        if etcd_in_range(k, start, end) {
          kvs.push({
            ..EtcdKeyValue::empty(),
            key: @utf8.encode(k),
            value: @utf8.encode(v),
          })
        }
      }
      EtcdRangeResponse::{ kvs, count: kvs.length().to_int64(), }.encode()
    } catch {
      _ => b""
    }
  })
  kv.register("DeleteRange", req => {
    try {
      let dr = EtcdDeleteRangeRequest::decode(req)
      let start = @utf8.decode_lossy(dr.key[:])
      let end = @utf8.decode_lossy(dr.range_end[:])
      let to_del : Array[String] = []
      for k, _ in store {
        if etcd_in_range(k, start, end) {
          to_del.push(k)
        }
      }
      for k in to_del {
        store.remove(k)
      }
      EtcdDeleteRangeResponse::{
        deleted: to_del.length().to_int64(),
        prev_kvs: [],
      }.encode()
    } catch {
      _ => b""
    }
  })
  server
  .group("etcdserverpb.Lease")
  .register("LeaseGrant", req => {
    try {
      let g = EtcdLeaseGrantRequest::decode(req)
      let id = next_lease.val
      next_lease.val = next_lease.val + 1L
      EtcdLeaseGrantResponse::{ id, ttl: g.ttl, error: "", }.encode()
    } catch {
      _ => b""
    }
  })
  server
}

///|
test "etcd discovery: register two instances, resolve both, then deregister" {
  let disc = EtcdDiscovery::new(
    EtcdClient::new(RpcChannel::connect(stateful_etcd_server())),
  )
  // Two instances of one service register under distinct lease keys and coexist.
  let _ = disc.register("greeter", Endpoint::new("10.0.0.1", 9090))
  let _ = disc.register("greeter", Endpoint::new("10.0.0.2", 9090))
  let eps = disc.resolve("greeter")
  assert_eq(eps.length(), 2)
  let addrs = eps.map(e => e.address())
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // An unregistered service resolves to nothing.
  assert_eq(disc.resolve("other").length(), 0)
  // The Resolve interface value the balancer consumes sees the same set.
  assert_eq(disc.resolver()("greeter").length(), 2)
  // Deregistering the service clears its instances.
  disc.deregister("greeter")
  assert_eq(disc.resolve("greeter").length(), 0)
}
