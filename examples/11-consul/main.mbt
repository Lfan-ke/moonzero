///|
/// The consul discovery driver's wire surface: the `service/register` request body,
/// the TTL check id, and the `health/service` JSON parser that turns a consul
/// agent's reply into endpoints. These are the request-shaping and parsing steps
/// that run on every backend; the `ConsulClient`/`ConsulDiscovery` layer that
/// carries them over a socket rides a sealed `ConsulHttp` transport (exercised by
/// the in-repo white-box tests — see the note in the examples README).
///
///     moon run examples/11-consul
#coverage.skip
fn main {
  try {
    // The body a registration PUTs: id, name, address, port, and the TTL check
    // consul deregisters `ttl*3` seconds after it stops passing.
    let body = @moonzero.consul_register_body(
      "greeter-1", "greeter", "10.0.0.1", 9090, 10,
    )
    println("register body: " + @utf8.decode_lossy(body[:]))
    println("check id: " + @moonzero.consul_check_id("greeter-1"))

    // The healthy-instances reply a `GET /v1/health/service/greeter` returns,
    // parsed into endpoints — with the Node.Address fallback consul clients apply.
    let health_src =
      #|[{"Service":{"Address":"10.0.0.1","Port":9090},"Node":{"Address":"node1"}},
      #|{"Service":{"Address":"","Port":9091},"Node":{"Address":"10.0.0.2"}}]
    let endpoints = @moonzero.consul_parse_health(@utf8.encode(health_src))
    println("parse_health -> " + addrs(endpoints))

    // A ConsulResponse pairs the agent's status with its raw body.
    let resp = @moonzero.ConsulResponse::new(200, @utf8.encode("ok"))
    println(
      "response status=" +
      resp.status().to_string() +
      " body=" +
      @utf8.decode_lossy(resp.body()[:]),
    )
  } catch {
    ConsulError(msg) => println("consul error: " + msg)
  }
}

///|
fn addrs(eps : Array[@moonzero.Endpoint]) -> String {
  let a = eps.map(e => e.address())
  a.sort()
  let sb = StringBuilder::new()
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
