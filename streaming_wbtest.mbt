///|
/// Concatenate two byte strings (test helper).
fn bcat(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
/// A real server-streaming zRPC round-trip over the moonrpc h2c transport: the
/// server registers a server-streaming handler that fans one request out into three
/// framed reply messages, and the channel reads all three back off the response
/// DATA frames, closed by `grpc-status: 0`. Each reply embeds the request bytes, so
/// the sequence can only be right if the request actually reached the handler and
/// every message survived the length-prefix framing.
test "zrpc server-streaming call returns every framed message in order" {
  let server = RpcServer::new(RpcServerConf::new(name="feed", port=9101))
  server
  .group("feed.Feed")
  .register_server_streaming("Tail", req => {
    [bcat(req, b"#1"), bcat(req, b"#2"), bcat(req, b"#3")]
  })
  let ch = RpcChannel::connect(server)
  match ch.call_server_streaming("/feed.Feed/Tail", b"log") {
    Ok(msgs) => {
      assert_eq(msgs.length(), 3)
      assert_eq(msgs[0], b"log#1")
      assert_eq(msgs[1], b"log#2")
      assert_eq(msgs[2], b"log#3")
    }
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// A server-streaming method may legitimately produce zero messages; the call still
/// completes on `grpc-status: 0` with an empty sequence.
test "zrpc server-streaming call with no messages completes OK" {
  let server = RpcServer::new(RpcServerConf::new())
  server.group("feed.Feed").register_server_streaming("Empty", _req => [])
  let ch = RpcChannel::connect(server)
  match ch.call_server_streaming("/feed.Feed/Empty", b"x") {
    Ok(msgs) => assert_eq(msgs.length(), 0)
    Err(_) => fail("empty stream should be OK")
  }
}

///|
/// A real client-streaming zRPC round-trip: the channel sends three request
/// messages as their own DATA frames, half-closes, and the handler — which sees the
/// whole collected sequence at once — returns a single reply built from all of
/// them. The reply encodes the count and the concatenation, so it is only right if
/// every message arrived, in order.
test "zrpc client-streaming call collects every request message" {
  let server = RpcServer::new(RpcServerConf::new())
  server
  .group("upload.Upload")
  .register_client_streaming("Send", msgs => {
    let buf = Buffer()
    buf.write_byte((msgs.length() + 0x30).to_byte())
    buf.write_byte(b':')
    for m in msgs {
      buf.write_bytes(m)
    }
    buf.to_bytes()
  })
  let ch = RpcChannel::connect(server)
  match ch.call_client_streaming("/upload.Upload/Send", [b"a", b"bb", b"ccc"]) {
    Ok(reply) => assert_eq(reply, b"3:abbccc")
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// A client-streaming call with no messages still runs the handler once with an
/// empty sequence.
test "zrpc client-streaming call with no messages runs the handler empty" {
  let server = RpcServer::new(RpcServerConf::new())
  server
  .group("upload.Upload")
  .register_client_streaming("Count", msgs => {
    if msgs.length() == 0 {
      b"none"
    } else {
      b"some"
    }
  })
  let ch = RpcChannel::connect(server)
  match ch.call_client_streaming("/upload.Upload/Count", []) {
    Ok(reply) => assert_eq(reply, b"none")
    Err(_) => fail("empty client stream should be OK")
  }
}

///|
/// A server-streaming call to an unregistered path comes back UNIMPLEMENTED, the
/// same trailers-only error the unary path reports for an unknown method.
test "zrpc server-streaming call to an unknown method returns Unimplemented" {
  let server = RpcServer::new(RpcServerConf::new())
  server.group("feed.Feed").register_server_streaming("Tail", _req => [b"x"])
  let ch = RpcChannel::connect(server)
  match ch.call_server_streaming("/feed.Feed/Missing", b"") {
    Ok(_) => fail("unknown method should not return OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unimplemented, true)
  }
}
