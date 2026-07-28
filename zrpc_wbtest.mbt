///|
/// A real unary zRPC round-trip over the moonrpc h2c transport: the server
/// registers a handler through a group, an in-process channel encodes a request
/// as HPACK HEADERS + length-prefixed DATA, the H2Server engine dispatches it, and
/// the channel reads the reply back off the response frames and `grpc-status: 0`
/// trailer. The handler concatenates a marker so the reply can only be right if
/// the request bytes actually reached it.
test "zrpc unary call goes through the h2c transport" {
  let server = RpcServer::new(RpcServerConf::new(name="greeter", port=9090))
  server
  .group("hello.Greeter")
  .register("SayHello", req => {
    let buf = Buffer()
    buf.write_bytes(b"hello, ")
    buf.write_bytes(req[:])
    buf.to_bytes()
  })
  let ch = RpcChannel::connect(server)
  match ch.call("/hello.Greeter/SayHello", b"world") {
    Ok(reply) => assert_eq(reply, b"hello, world")
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// Distinct message payloads round-trip intact, and a second call on the same
/// channel still decodes — proving the HPACK dynamic table stays in sync across
/// calls rather than only working on the first.
test "zrpc channel carries multiple sequential calls" {
  let server = RpcServer::new(RpcServerConf::new())
  server.group("echo.Echo").register("Echo", req => req)
  let ch = RpcChannel::connect(server)
  match ch.call("/echo.Echo/Echo", b"first") {
    Ok(reply) => assert_eq(reply, b"first")
    Err(_) => fail("first call failed")
  }
  match ch.call("/echo.Echo/Echo", b"second-and-longer") {
    Ok(reply) => assert_eq(reply, b"second-and-longer")
    Err(_) => fail("second call failed")
  }
  // A binary payload with NUL and high bytes survives the DATA framing.
  match ch.call("/echo.Echo/Echo", b"\x00\xff\x01\xfe") {
    Ok(reply) => assert_eq(reply, b"\x00\xff\x01\xfe")
    Err(_) => fail("binary call failed")
  }
}

///|
/// An empty request and an empty reply are a valid unary exchange.
test "zrpc unary call with empty payloads" {
  let server = RpcServer::new(RpcServerConf::new())
  server.group("ping.Ping").register("Ping", _req => b"")
  let ch = RpcChannel::connect(server)
  match ch.call("/ping.Ping/Ping", b"") {
    Ok(reply) => assert_eq(reply.length(), 0)
    Err(_) => fail("ping failed")
  }
}

///|
/// A call to an unregistered path comes back as `UNIMPLEMENTED` over the wire —
/// the trailers-only response a real gRPC server sends for an unknown method.
test "zrpc call to an unknown method returns Unimplemented" {
  let server = RpcServer::new(RpcServerConf::new())
  server.group("hello.Greeter").register("SayHello", req => req)
  let ch = RpcChannel::connect(server)
  match ch.call("/hello.Greeter/DoesNotExist", b"x") {
    Ok(_) => fail("unknown method should not return OK")
    Err(status) => assert_eq(status == @moonrpc.Status::Unimplemented, true)
  }
}

///|
/// The transport dispatches by path: two methods on one service each reach their
/// own handler.
test "zrpc routes each method to its own handler over the transport" {
  let server = RpcServer::new(RpcServerConf::new())
  let g = server.group("order.OrderService")
  g.register("Create", _req => b"created")
  g.register("Cancel", _req => b"cancelled")
  let ch = RpcChannel::connect(server)
  match ch.call("/order.OrderService/Create", b"") {
    Ok(reply) => assert_eq(reply, b"created")
    Err(_) => fail("Create failed")
  }
  match ch.call("/order.OrderService/Cancel", b"") {
    Ok(reply) => assert_eq(reply, b"cancelled")
    Err(_) => fail("Cancel failed")
  }
}

///|
/// `status_of_code` covers the whole canonical range and rejects out-of-range
/// codes as `Unknown`.
test "status_of_code maps the canonical range" {
  assert_eq(status_of_code(0) == @moonrpc.Status::Ok, true)
  assert_eq(status_of_code(12) == @moonrpc.Status::Unimplemented, true)
  assert_eq(status_of_code(16) == @moonrpc.Status::Unauthenticated, true)
  assert_eq(status_of_code(99) == @moonrpc.Status::Unknown, true)
  assert_eq(status_of_code(-1) == @moonrpc.Status::Unknown, true)
}
