///|
/// The etcd v3 discovery driver end to end: the `etcdserverpb` protobuf messages
/// round-trip on moonrpc's runtime, and an `EtcdDiscovery` / `EtcdClient` register,
/// resolve, and deregister against an in-process mock etcd — the same gRPC calls
/// go-zero's `discov` makes against a live cluster.
///
///     moon run examples/10-etcd
#coverage.skip
fn main {
  try {
    // The KeyValue message encodes to etcd's wire format and decodes back exactly.
    let kv = @moonzero.EtcdKeyValue::{
      ..@moonzero.EtcdKeyValue::empty(),
      key: @utf8.encode("moonzero/greeter/1"),
      value: @utf8.encode("10.0.0.1:9090"),
      mod_revision: 233L,
      lease: 66666L,
    }
    let round = @moonzero.EtcdKeyValue::decode(kv.encode())
    println(
      "KeyValue round-trips: " +
      (round == kv).to_string() +
      " value=" +
      @utf8.decode_lossy(round.value[:]) +
      " mod_rev=" +
      round.mod_revision.to_string(),
    )

    // Key layout helpers: the per-service prefix and the range-end for a prefix scan.
    let prefix = @moonzero.etcd_service_prefix("moonzero/", "greeter")
    println(
      "service prefix: " +
      prefix +
      " range_end: " +
      @utf8.decode_lossy(@moonzero.etcd_prefix_end(@utf8.encode(prefix))[:]),
    )

    // The discovery driver over a mock etcd: register two instances, resolve, drop.
    let disc = @moonzero.EtcdDiscovery::new(
      @moonzero.EtcdClient::new(@moonzero.RpcChannel::connect(mock_etcd())),
    )
    let lease1 = disc.register(
      "greeter",
      @moonzero.Endpoint::new("10.0.0.1", 9090),
    )
    let _ = disc.register("greeter", @moonzero.Endpoint::new("10.0.0.2", 9090))
    println("registered lease id=" + lease1.to_string())
    println("etcd resolve: " + addrs(disc.resolve("greeter")))
    println("resolver interface: " + addrs(disc.resolver()("greeter")))
    disc.deregister("greeter")
    println(
      "after deregister: " +
      disc.resolve("greeter").length().to_string() +
      " instances",
    )

    // The raw KV/Lease client the driver is built on.
    let client = @moonzero.EtcdClient::new(
      @moonzero.RpcChannel::connect(mock_etcd()),
    )
    let lease = client.lease_grant({ ttl: 30L, id: 0L, })
    println(
      "LeaseGrant id=" + lease.id.to_string() + " ttl=" + lease.ttl.to_string(),
    )
    let _ = client.put({
      key: @utf8.encode("moonzero/svc/1"),
      value: @utf8.encode("10.0.0.9:7000"),
      lease: lease.id,
    })
    let key = @utf8.encode("moonzero/svc/")
    let resp = client.range({
      key,
      range_end: @moonzero.etcd_prefix_end(key),
      limit: 0L,
    })
    println(
      "Range count=" + resp.count.to_string() + " value=" + first_value(resp),
    )

    // The Watch server-streaming call: open a watch and read the response stream
    // (the created ack, then a batch carrying a Put event).
    let wkey = @utf8.encode("moonzero/greeter/")
    let stream = client.watch(
      @moonzero.EtcdWatchRequest::Create({
        key: wkey,
        range_end: @moonzero.etcd_prefix_end(wkey),
        start_revision: 0L,
      }),
    )
    println(
      "Watch responses=" +
      stream.length().to_string() +
      " created=" +
      stream[0].created.to_string() +
      " event=" +
      watch_event(stream[1]),
    )
  } catch {
    _ => println("unexpected etcd error")
  }
}

///|
fn watch_event(resp : @moonzero.EtcdWatchResponse) -> String {
  if resp.events.length() == 0 {
    "none"
  } else {
    let ev = resp.events[0]
    let kind = if ev.event_type == @moonzero.EtcdEventType::Put {
      "Put"
    } else {
      "Delete"
    }
    kind + " " + @utf8.decode_lossy(ev.kv.value[:])
  }
}

///|
/// A stateful in-memory mock etcd backing Put / Range / DeleteRange / LeaseGrant
/// over the real gRPC methods, so a key one call puts is visible to a later Range —
/// the same server an `EtcdDiscovery` drives, minus the network.
fn mock_etcd() -> @moonzero.RpcServer {
  let store : Map[String, String] = Map([])
  let next_lease : Ref[Int64] = { val: 1000L, }
  let server = @moonzero.RpcServer::new(@moonzero.RpcServerConf::new())
  let kv = server.group("etcdserverpb.KV")
  kv.register("Put", req => {
    try {
      let p = @moonzero.EtcdPutRequest::decode(req)
      store[@utf8.decode_lossy(p.key[:])] = @utf8.decode_lossy(p.value[:])
      @moonzero.EtcdPutResponse::{ prev_kv: @moonzero.EtcdKeyValue::empty(), }.encode()
    } catch {
      _ => b""
    }
  })
  kv.register("Range", req => {
    try {
      let rr = @moonzero.EtcdRangeRequest::decode(req)
      let start = @utf8.decode_lossy(rr.key[:])
      let end = @utf8.decode_lossy(rr.range_end[:])
      let kvs : Array[@moonzero.EtcdKeyValue] = []
      for k, v in store {
        if in_range(k, start, end) {
          kvs.push(@moonzero.EtcdKeyValue::{
            ..@moonzero.EtcdKeyValue::empty(),
            key: @utf8.encode(k),
            value: @utf8.encode(v),
          })
        }
      }
      @moonzero.EtcdRangeResponse::{ kvs, count: kvs.length().to_int64(), }.encode()
    } catch {
      _ => b""
    }
  })
  kv.register("DeleteRange", req => {
    try {
      let dr = @moonzero.EtcdDeleteRangeRequest::decode(req)
      let start = @utf8.decode_lossy(dr.key[:])
      let end = @utf8.decode_lossy(dr.range_end[:])
      let gone : Array[String] = []
      for k, _ in store {
        if in_range(k, start, end) {
          gone.push(k)
        }
      }
      for k in gone {
        store.remove(k)
      }
      @moonzero.EtcdDeleteRangeResponse::{
        deleted: gone.length().to_int64(),
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
      let g = @moonzero.EtcdLeaseGrantRequest::decode(req)
      let id = next_lease.val
      next_lease.val = next_lease.val + 1L
      @moonzero.EtcdLeaseGrantResponse::{ id, ttl: g.ttl, error: "", }.encode()
    } catch {
      _ => b""
    }
  })
  server
  .group("etcdserverpb.Watch")
  .register_server_streaming("Watch", req => {
    try {
      let _ = @moonzero.EtcdWatchRequest::decode(req)
      // etcd answers a watch with a created ack, then a response per change batch.
      let ack = @moonzero.EtcdWatchResponse::{
        watch_id: 1L,
        created: true,
        canceled: false,
        events: [],
      }
      let batch = @moonzero.EtcdWatchResponse::{
        watch_id: 1L,
        created: false,
        canceled: false,
        events: [
          @moonzero.EtcdEvent::{
            event_type: @moonzero.EtcdEventType::Put,
            kv: @moonzero.EtcdKeyValue::{
              ..@moonzero.EtcdKeyValue::empty(),
              key: @utf8.encode("moonzero/greeter/1"),
              value: @utf8.encode("10.0.0.1:9090"),
            },
          },
        ],
      }
      [ack.encode(), batch.encode()]
    } catch {
      _ => []
    }
  })
  server
}

///|
/// etcd's half-open `[start, end)` byte range: an empty `end` is a single-key get,
/// otherwise a prefix scan whose keys all share `start` as a prefix.
fn in_range(k : String, start : String, end : String) -> Bool {
  if end == "" {
    k == start
  } else {
    has_prefix(k, start)
  }
}

///|
fn has_prefix(s : String, p : String) -> Bool {
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
fn first_value(resp : @moonzero.EtcdRangeResponse) -> String {
  if resp.kvs.length() == 0 {
    "none"
  } else {
    @utf8.decode_lossy(resp.kvs[0].value[:])
  }
}

///|
fn addrs(eps : Array[@moonzero.Endpoint]) -> String {
  let a = eps.map(e => e.address())
  a.sort()
  let sb = StringBuilder()
  sb.write_char('[')
  for i = 0; i < a.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(a[i])
  }
  sb.write_char(']')
  sb.to_string()
}
