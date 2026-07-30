// Integration test against a REAL consul agent. Gated on `MOON_CONSUL_TEST`, so it is
// skipped in the normal suite and runs only in the CI job that stands up a consul
// container. It drives the exact discovery wire — register a service with a TTL check,
// pass the check, resolve the healthy set, deregister — over the real HTTP socket,
// reusing the root's request-body builder and health parser, so a green run proves the
// HTTP/1 codec and the discovery flow against a live consul.

///|
/// The consul host for the integration test: `MOON_CONSUL_HOST`, or localhost.
fn consul_test_host() -> String {
  match @env.get_env_var("MOON_CONSUL_HOST") {
    Some(h) => h
    None => "127.0.0.1"
  }
}

///|
/// Register `endpoint` for `service` and pass its TTL check so it is healthy at once.
async fn consul_put_healthy(
  sock : ConsulSocket,
  service : String,
  id : String,
  host : String,
  port : Int,
) -> Unit {
  let ok = sock.request(
    "PUT",
    "/v1/agent/service/register",
    @moonzero.consul_register_body(id, service, host, port, 30),
  )
  assert_eq(ok.status(), 200)
  let passed = sock.request("PUT", "/v1/agent/check/pass/service:" + id, b"")
  assert_eq(passed.status(), 200)
}

///|
async test "integration: consul discovery register/resolve/deregister over a real consul" {
  guard @env.get_env_var("MOON_CONSUL_TEST") is Some(_) else { return }
  let sock = ConsulSocket::new(consul_test_host())
  let id1 = "greeter-10.0.0.1-9090"
  let id2 = "greeter-10.0.0.2-9090"
  // Clean any leftover from a prior run.
  let _ = sock.request("PUT", "/v1/agent/service/deregister/" + id1, b"")
  let _ = sock.request("PUT", "/v1/agent/service/deregister/" + id2, b"")
  // Register two healthy instances.
  consul_put_healthy(sock, "greeter", id1, "10.0.0.1", 9090)
  consul_put_healthy(sock, "greeter", id2, "10.0.0.2", 9090)
  // Resolve the healthy set.
  let resp = sock.request("GET", "/v1/health/service/greeter?passing=true", b"")
  assert_eq(resp.status(), 200)
  let eps = @moonzero.consul_parse_health(resp.body())
  assert_eq(eps.length(), 2)
  let addrs = eps.map(e => e.address())
  assert_eq(addrs.contains("10.0.0.1:9090"), true)
  assert_eq(addrs.contains("10.0.0.2:9090"), true)
  // Deregister both; the healthy set is then empty.
  let _ = sock.request("PUT", "/v1/agent/service/deregister/" + id1, b"")
  let _ = sock.request("PUT", "/v1/agent/service/deregister/" + id2, b"")
  let after = sock.request(
    "GET", "/v1/health/service/greeter?passing=true", b"",
  )
  assert_eq(@moonzero.consul_parse_health(after.body()).length(), 0)
}
