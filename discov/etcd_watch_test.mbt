// The etcd Watch stream, driven against a mock etcd Watch RPC over a real socket: the
// server streams a `created` acknowledgement then a PUT event, and `EtcdSocket::watch` reads
// and decodes both off the wire. The real-etcd counterpart is gated in the integration test.

///|
async test "etcd watch: reads created then a PUT event off a streamed Watch RPC" {
  @async.with_task_group(g => {
    let created : @moonzero.EtcdWatchResponse = {
      watch_id: 7L,
      created: true,
      canceled: false,
      events: [],
    }
    let event : @moonzero.EtcdWatchResponse = {
      watch_id: 7L,
      created: false,
      canceled: false,
      events: [
        {
          event_type: @moonzero.EtcdEventType::Put,
          kv: {
            key: b"svc/1",
            create_revision: 2L,
            mod_revision: 3L,
            version: 1L,
            value: b"10.0.0.1:9090",
            lease: 0L,
          },
        },
      ],
    }
    let server = @net.GrpcServer::new()
    server.register_server_streaming("/etcdserverpb.Watch/Watch", (_ctx, _req) => {
      [created.encode(), event.encode()]
    })
    let ts = g.spawn(() => server.serve(port=18140))
    @async.sleep(300)
    let sock = EtcdSocket::connect("127.0.0.1", 18140)
    let responses = sock.watch(
      { key: b"svc/", range_end: b"svc0", start_revision: 0L },
      2,
    )
    sock.close()
    ts.cancel()
    assert_eq(responses.length(), 2)
    assert_eq(responses[0].created, true)
    assert_eq(responses[1].events.length(), 1)
    assert_eq(
      responses[1].events[0].event_type == @moonzero.EtcdEventType::Put,
      true,
    )
    assert_eq(responses[1].events[0].kv.value == b"10.0.0.1:9090", true)
  })
}
