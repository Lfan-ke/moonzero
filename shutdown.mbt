///|
/// A graceful-shutdown coordinator for a zRPC server (← go-zero's
/// `proc.AddShutdownListener` + gRPC's `GracefulStop`): once shutdown is
/// initiated the server stops admitting new calls, but calls already in flight are
/// allowed to run to completion. A call brackets its work between `begin_call` and
/// `end_call`; `begin_call` returns `false` when the server is shutting down, which
/// the transport surfaces as `Unavailable` — exactly the status a client sees once
/// a server has stopped listening. The server is fully drained once shutdown has
/// been initiated and no calls remain in flight.
///
/// The counter is plain mutable state, which is safe under `moonbitlang/async`'s
/// cooperative single-threaded scheduling: `begin_call`/`end_call` never yield, so
/// the count is only observed at await points between them.
pub struct ShutdownCoordinator {
  mut shutting_down : Bool
  mut in_flight : Int
}

///|
/// A coordinator that is serving normally with no calls in flight.
pub fn ShutdownCoordinator::new() -> ShutdownCoordinator {
  { shutting_down: false, in_flight: 0, }
}

///|
/// Admit a new call: register it as in-flight and return `true`, unless shutdown
/// has been initiated, in which case the call is refused (`false`) and the count is
/// left untouched.
pub fn ShutdownCoordinator::begin_call(self : ShutdownCoordinator) -> Bool {
  if self.shutting_down {
    false
  } else {
    self.in_flight = self.in_flight + 1
    true
  }
}

///|
/// Mark an admitted call finished, dropping it from the in-flight count. Only call
/// it for a call that `begin_call` admitted; the count never goes below zero.
pub fn ShutdownCoordinator::end_call(self : ShutdownCoordinator) -> Unit {
  if self.in_flight > 0 {
    self.in_flight = self.in_flight - 1
  }
}

///|
/// Begin the graceful shutdown: from now on `begin_call` refuses new calls while
/// in-flight ones keep running. Idempotent.
pub fn ShutdownCoordinator::initiate_shutdown(
  self : ShutdownCoordinator,
) -> Unit {
  self.shutting_down = true
}

///|
/// Whether shutdown has been initiated.
pub fn ShutdownCoordinator::is_shutting_down(
  self : ShutdownCoordinator,
) -> Bool {
  self.shutting_down
}

///|
/// The number of calls currently in flight.
pub fn ShutdownCoordinator::in_flight(self : ShutdownCoordinator) -> Int {
  self.in_flight
}

///|
/// Whether the server is fully drained: shutdown initiated and no call in flight.
/// A supervisor loops on this (yielding between checks) to know the last in-flight
/// RPC has finished and the process may exit.
pub fn ShutdownCoordinator::is_drained(self : ShutdownCoordinator) -> Bool {
  self.shutting_down && self.in_flight == 0
}

///|
/// Dispatch a unary call through the shutdown gate: refuse with `Unavailable` when
/// the server is shutting down, otherwise run the handler and count it as in-flight
/// for the duration so a concurrent shutdown drains behind it. The gate wraps
/// `RpcServer::dispatch`, so an unregistered path still yields `Unimplemented`.
pub fn RpcServer::dispatch_graceful(
  self : RpcServer,
  coord : ShutdownCoordinator,
  path : String,
  request : Bytes,
) -> Result[Bytes, @moonrpc.Status] {
  if !coord.begin_call() {
    return Err(@moonrpc.Status::Unavailable)
  }
  let result = self.dispatch(path, request)
  coord.end_call()
  result
}
