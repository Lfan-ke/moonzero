// Integration test against a REAL etcd. Gated on `MOON_ETCD_TEST`, so it is skipped in
// the normal suite and runs only in the CI job that stands up an etcd container. It
// drives the exact discovery wire — a lease grant plus a Put to register, a prefix
// Range to resolve, a DeleteRange to deregister — over the real gRPC socket, using the
// same key layout (`etcd_service_prefix` / `etcd_prefix_end`) the in-process driver
// uses, so a green run proves the etcd message codec and the discovery flow against a
// live etcd.

///|
/// The etcd host for the integration test: `MOON_ETCD_HOST`, or localhost.
fn etcd_test_host() -> String {
  match @env.get_env_var("MOON_ETCD_HOST") {
    Some(h) => h
    None => "127.0.0.1"
  }
}

///|
/// Grant a lease and Put `endpoint` under `<prefix>/<lease-id>`, returning the lease id.
async fn etcd_put_instance(
  sock : EtcdSocket,
  svc_prefix : String,
  endpoint : @moonzero.Endpoint,
) -> Int64 {
  let lease = sock.lease_grant({ ttl: 30, id: 0 })
  let _ = sock.put({
    key: @utf8.encode(svc_prefix + lease.id.to_string()),
    value: @utf8.encode(endpoint.address()),
    lease: lease.id,
  })
  lease.id
}

///|
async test "integration: etcd discovery register/resolve/deregister over a real etcd" {
  guard @env.get_env_var("MOON_ETCD_TEST") is Some(_) else { return }
  let sock = EtcdSocket::connect(etcd_test_host(), 2379)
  defer sock.close()
  let svc_prefix = @moonzero.etcd_service_prefix("moonzero-ci/", "greeter")
  let prefix_bytes = @utf8.encode(svc_prefix)
  let range_end = @moonzero.etcd_prefix_end(prefix_bytes)
  // Clean any leftover from a prior run.
  let _ = sock.delete_range({ key: prefix_bytes, range_end, prev_kv: false })
  // Register two instances (lease grant + Put).
  let _ = etcd_put_instance(
    sock,
    svc_prefix,
    @moonzero.Endpoint::new("10.0.0.1", 9090),
  )
  let _ = etcd_put_instance(
    sock,
    svc_prefix,
    @moonzero.Endpoint::new("10.0.0.2", 9090),
  )
  // Resolve: Range the prefix.
  let resp = sock.range({ key: prefix_bytes, range_end, limit: 0 })
  assert_eq(resp.kvs.length(), 2)
  let addrs = resp.kvs.map(kv => @utf8.decode_lossy(kv.value[:]))
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // Deregister: DeleteRange the prefix clears both.
  let del = sock.delete_range({ key: prefix_bytes, range_end, prev_kv: false })
  assert_eq(del.deleted, 2)
  let after = sock.range({ key: prefix_bytes, range_end, limit: 0 })
  assert_eq(after.kvs.length(), 0)
}

///|
async test "integration: etcd watch observes a live PUT over a real watch stream" {
  guard @env.get_env_var("MOON_ETCD_TEST") is Some(_) else { return }
  @async.with_task_group(g => {
    let key = @utf8.encode("moonzero-ci/watch/probe")
    // Clean any leftover on a setup connection.
    let setup = EtcdSocket::connect(etcd_test_host(), 2379)
    let _ = setup.delete_range({ key, range_end: b"", prev_kv: false })
    setup.close()
    // A concurrent publisher Puts the key once the watch has had time to establish.
    let putter = g.spawn(() => {
      @async.sleep(500)
      let pub_conn = EtcdSocket::connect(etcd_test_host(), 2379)
      let _ = pub_conn.put({
        key,
        value: @utf8.encode("10.0.0.1:9090"),
        lease: 0L,
      })
      pub_conn.close()
    })
    // Watch and read the created ack plus the PUT event the publisher triggers.
    let sock = EtcdSocket::connect(etcd_test_host(), 2379)
    let responses = sock.watch({ key, range_end: b"", start_revision: 0L }, 2)
    sock.close()
    let _ = putter.wait()
    assert_eq(responses.length() >= 2, true)
    assert_eq(responses[0].created, true)
    let mut saw_put = false
    for r in responses {
      for e in r.events {
        if e.event_type == @moonzero.EtcdEventType::Put &&
          e.kv.value == @utf8.encode("10.0.0.1:9090") {
          saw_put = true
        }
      }
    }
    assert_eq(saw_put, true)
    // Cleanup.
    let cleanup = EtcdSocket::connect(etcd_test_host(), 2379)
    let _ = cleanup.delete_range({ key, range_end: b"", prev_kv: false })
    cleanup.close()
  })
}
