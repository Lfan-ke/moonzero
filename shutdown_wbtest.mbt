///|
/// A fresh coordinator admits calls and is neither shutting down nor drained.
test "shutdown coordinator starts open" {
  let coord = ShutdownCoordinator::new()
  assert_eq(coord.is_shutting_down(), false)
  assert_eq(coord.is_drained(), false)
  assert_eq(coord.begin_call(), true)
  assert_eq(coord.in_flight(), 1)
  coord.end_call()
  assert_eq(coord.in_flight(), 0)
}

///|
/// Once shutdown is initiated, new calls are refused; an already-admitted call is
/// still allowed to finish, and the server is drained only after it does. This is
/// the graceful-drain contract: reject the new, finish the in-flight.
test "shutdown drains the in-flight call and refuses new ones" {
  let coord = ShutdownCoordinator::new()
  // one call is in flight when shutdown starts.
  assert_eq(coord.begin_call(), true)
  coord.initiate_shutdown()
  assert_eq(coord.is_shutting_down(), true)
  // a new call is refused while draining, and does not touch the count.
  assert_eq(coord.begin_call(), false)
  assert_eq(coord.in_flight(), 1)
  assert_eq(coord.is_drained(), false)
  // the in-flight call finishes -> fully drained.
  coord.end_call()
  assert_eq(coord.in_flight(), 0)
  assert_eq(coord.is_drained(), true)
}

///|
/// The graceful dispatch gate serves normally before shutdown and refuses with
/// `Unavailable` after, while an unknown method still maps to `Unimplemented`.
test "dispatch_graceful serves, then refuses with Unavailable after shutdown" {
  let server = RpcServer::new(RpcServerConf::new())
  server.group("greet.Greeter").register("Hello", req => dcat(b"hi:", req))
  let coord = ShutdownCoordinator::new()
  match server.dispatch_graceful(coord, "/greet.Greeter/Hello", b"leo") {
    Ok(reply) => assert_eq(reply, b"hi:leo")
    Err(s) => fail("expected OK, got " + s.name())
  }
  // unknown method still reports Unimplemented while serving.
  match server.dispatch_graceful(coord, "/greet.Greeter/Missing", b"") {
    Ok(_) => fail("unknown method should not be OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unimplemented, true)
  }
  assert_eq(coord.in_flight(), 0)
  coord.initiate_shutdown()
  match server.dispatch_graceful(coord, "/greet.Greeter/Hello", b"leo") {
    Ok(_) => fail("a shutting-down server must refuse new calls")
    Err(s) => assert_eq(s == @moonrpc.Status::Unavailable, true)
  }
}
