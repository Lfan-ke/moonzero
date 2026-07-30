// A real gRPC round-trip for the etcd client: a mock etcd server registers the
// KV / Lease / Watch methods on moonzero's RpcServer, and the EtcdClient calls them
// over an in-process RpcChannel — the request is encoded, framed, driven through the
// h2c engine, decoded by the handler, and its response decoded back. No socket, so it
// runs on every backend; the same client drives a real etcd over a socket-backed
// channel.

///|
/// Build a mock etcd server answering the KV / Lease / Watch methods the client uses.
fn mock_etcd_server() -> RpcServer {
  let server = RpcServer::new(RpcServerConf::new())
  let kv = server.group("etcdserverpb.KV")
  // Range echoes the requested key back in a single result, so the round-trip is
  // observable in both directions.
  kv.register("Range", req => {
    let rr = EtcdRangeRequest::decode(req) catch {
      _ => EtcdRangeRequest::{ key: b"", range_end: b"", limit: 0 }
    }
    EtcdRangeResponse::{
      kvs: [
        {
          ..EtcdKeyValue::empty(),
          key: rr.key,
          value: b"1.2.3.4",
          mod_revision: 5,
        },
      ],
      count: 1,
    }.encode()
  })
  kv.register("Put", _req => {
    EtcdPutResponse::{ prev_kv: EtcdKeyValue::empty() }.encode()
  })
  kv.register("DeleteRange", _req => {
    EtcdDeleteRangeResponse::{ deleted: 1, prev_kvs: [] }.encode()
  })
  server
  .group("etcdserverpb.Lease")
  .register("LeaseGrant", _req => {
    EtcdLeaseGrantResponse::{ id: 99, ttl: 60, error: "" }.encode()
  })
  server
  .group("etcdserverpb.Watch")
  .register_server_streaming("Watch", _req => {
    [
      EtcdWatchResponse::{
        watch_id: 1,
        created: true,
        canceled: false,
        events: [],
      }.encode(),
      EtcdWatchResponse::{
        watch_id: 1,
        created: false,
        canceled: false,
        events: [
          {
            event_type: Put,
            kv: { ..EtcdKeyValue::empty(), key: b"svc/a", value: b"1.2.3.4" },
          },
        ],
      }.encode(),
    ]
  })
  server
}

///|
test "etcd client: unary Range/Put/DeleteRange/LeaseGrant over a mock etcd gRPC server" {
  let client = EtcdClient::new(RpcChannel::connect(mock_etcd_server()))
  // Range: our key comes back in the response.
  let resp = client.range({ key: b"svc/a", range_end: b"", limit: 0 })
  assert_eq(resp.count, 1)
  assert_eq(resp.kvs[0].key == b"svc/a", true)
  assert_eq(resp.kvs[0].value == b"1.2.3.4", true)
  // LeaseGrant: the assigned lease id and ttl.
  let lease = client.lease_grant({ ttl: 60, id: 0 })
  assert_eq(lease.id, 99)
  assert_eq(lease.ttl, 60)
  // Put and DeleteRange complete the register/deregister pair.
  let _ = client.put({ key: b"svc/a", value: b"1.2.3.4", lease: 99 })
  let del = client.delete_range({
    key: b"svc/a",
    range_end: b"",
    prev_kv: false,
  })
  assert_eq(del.deleted, 1)
}

///|
test "etcd client: Watch streams the created response and change events" {
  let client = EtcdClient::new(RpcChannel::connect(mock_etcd_server()))
  let responses = client.watch(
    Create({ key: b"svc/", range_end: b"svc0", start_revision: 0 }),
  )
  assert_eq(responses.length(), 2)
  assert_eq(responses[0].created, true)
  assert_eq(responses[1].events.length(), 1)
  assert_eq(responses[1].events[0].kv.key == b"svc/a", true)
}
