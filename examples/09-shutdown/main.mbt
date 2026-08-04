///|
/// The graceful-shutdown gate a serving zRPC server drains through: before
/// shutdown, calls dispatch normally and count as in-flight; once shutdown is
/// initiated new calls come back Unavailable while in-flight ones run to
/// completion, and `is_drained` reports when the last one has finished.
///
///     moon run examples/09-shutdown
#coverage.skip
fn main {
  let rpc = @moonzero.RpcServer::new(
    @moonzero.RpcServerConf::new(name="greeter"),
  )
  rpc.group("hello.Greeter").register("SayHello", req => req)
  let coord = @moonzero.ShutdownCoordinator::new()

  // While serving, a graceful dispatch runs the handler and returns Ok.
  println(
    "serving dispatch -> " +
    result(
      rpc.dispatch_graceful(
        coord,
        "/hello.Greeter/SayHello",
        @utf8.encode("emm"),
      ),
    ),
  )
  println(
    "  shutting_down=" +
    coord.is_shutting_down().to_string() +
    " in_flight=" +
    coord.in_flight().to_string(),
  )

  // The bracket a running call holds: begin_call registers it in-flight.
  let admitted = coord.begin_call()
  println(
    "mid-flight call admitted=" +
    admitted.to_string() +
    " in_flight=" +
    coord.in_flight().to_string() +
    " drained=" +
    coord.is_drained().to_string(),
  )

  // Shutdown begins: new calls are refused Unavailable, the in-flight one is not.
  coord.initiate_shutdown()
  println(
    "after initiate_shutdown, new dispatch -> " +
    result(
      rpc.dispatch_graceful(coord, "/hello.Greeter/SayHello", @utf8.encode("x")),
    ),
  )
  println("  still draining, drained=" + coord.is_drained().to_string())

  // The last in-flight call finishes and the server is fully drained.
  coord.end_call()
  println(
    "last call ended, in_flight=" +
    coord.in_flight().to_string() +
    " drained=" +
    coord.is_drained().to_string(),
  )
}

///|
fn result(r : Result[Bytes, @moonrpc.Status]) -> String {
  match r {
    Ok(b) => "ok(" + @utf8.decode_lossy(b[:]) + ")"
    Err(s) => "err(" + s.name() + ")"
  }
}
