///|
/// Concatenate two byte strings (test helper).
fn dcat(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
/// A real bidirectional zRPC round-trip over the moonrpc h2c transport, driven one
/// message at a time so the interleaving is observable: each `send` gets back
/// exactly the echo for the message just sent (not a batch at the end), and
/// `close_send` runs the server's `on_end` and returns its farewell. This is only
/// possible if request and reply frames truly flow both ways on the open stream.
test "zrpc bidi call interleaves a reply per message, then a farewell on close" {
  let server = RpcServer::new(RpcServerConf::new(name="chat", port=9201))
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [dcat(b"re:", m)],
    on_end: () => [b"bye"],
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/chat.Chat/Echo")
  let first = call.send(b"one")
  assert_eq(first.length(), 1)
  assert_eq(first[0], b"re:one")
  let second = call.send(b"two")
  assert_eq(second.length(), 1)
  assert_eq(second[0], b"re:two")
  match call.close_send() {
    Ok(final_msgs) => {
      assert_eq(final_msgs.length(), 1)
      assert_eq(final_msgs[0], b"bye")
    }
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// The one-shot convenience drives the whole exchange and returns every reply in
/// emission order: an echo per request followed by the `on_end` farewell.
test "zrpc call_bidi_streaming returns the interleaved replies then the terminator" {
  let server = RpcServer::new(RpcServerConf::new())
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [dcat(b"re:", m)],
    on_end: () => [b"bye"],
  })
  let ch = RpcChannel::connect(server)
  match ch.call_bidi_streaming("/chat.Chat/Echo", [b"one", b"two", b"three"]) {
    Ok(msgs) => {
      assert_eq(msgs.length(), 4)
      assert_eq(msgs[0], b"re:one")
      assert_eq(msgs[1], b"re:two")
      assert_eq(msgs[2], b"re:three")
      assert_eq(msgs[3], b"bye")
    }
    Err(s) => fail("expected OK, got " + s.name())
  }
}

///|
/// A bidi handler that buffers every message and only replies at half-close (a
/// reduce-over-the-stream shape): each `send` returns no messages, and `close_send`
/// returns the single aggregate. Distinguishes the `on_end` terminator from the
/// per-message path — if `on_end` were dropped the call would yield nothing.
test "zrpc bidi handler may defer all replies to on_end" {
  let server = RpcServer::new(RpcServerConf::new())
  server
  .group("agg.Agg")
  .register_bidi_streaming("Reduce", () => {
    let parts : Array[Bytes] = []
    BidiStreamHandler::{
      on_message: m => {
        parts.push(m)
        []
      },
      on_end: () => {
        let buf = Buffer()
        for p in parts {
          buf.write_bytes(p)
        }
        [buf.to_bytes()]
      },
    }
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/agg.Agg/Reduce")
  assert_eq(call.send(b"a").length(), 0)
  assert_eq(call.send(b"b").length(), 0)
  assert_eq(call.send(b"c").length(), 0)
  match call.close_send() {
    Ok(final_msgs) => {
      assert_eq(final_msgs.length(), 1)
      assert_eq(final_msgs[0], b"abc")
    }
    Err(_) => fail("aggregate should be OK")
  }
}

///|
/// A bidi handler may emit several replies for one request; every one arrives on
/// that `send`.
test "zrpc bidi handler may fan one message out into several replies" {
  let server = RpcServer::new(RpcServerConf::new())
  server
  .group("fan.Fan")
  .register_bidi_streaming("Out", () => BidiStreamHandler::{
    on_message: m => [dcat(m, b"-1"), dcat(m, b"-2")],
    on_end: () => [],
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/fan.Fan/Out")
  let out = call.send(b"x")
  assert_eq(out.length(), 2)
  assert_eq(out[0], b"x-1")
  assert_eq(out[1], b"x-2")
  match call.close_send() {
    Ok(final_msgs) => assert_eq(final_msgs.length(), 0)
    Err(_) => fail("no on_end replies is still OK")
  }
}

///|
/// A bidi call to an unregistered path comes back UNIMPLEMENTED — the trailers-only
/// status the engine answers during the request HEADERS, captured by `open_bidi`
/// before any message is sent.
test "zrpc bidi call to an unknown method returns Unimplemented" {
  let server = RpcServer::new(RpcServerConf::new())
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [m],
    on_end: () => [],
  })
  let ch = RpcChannel::connect(server)
  match ch.call_bidi_streaming("/chat.Chat/Missing", [b"hi"]) {
    Ok(_) => fail("unknown method should not return OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unimplemented, true)
  }
}

///|
/// Calling `close_send` twice is refused with `Cancelled`; the stream is already
/// half-closed.
test "zrpc bidi close_send is idempotent-guarded" {
  let server = RpcServer::new(RpcServerConf::new())
  server
  .group("chat.Chat")
  .register_bidi_streaming("Echo", () => BidiStreamHandler::{
    on_message: m => [m],
    on_end: () => [b"bye"],
  })
  let ch = RpcChannel::connect(server)
  let call = ch.open_bidi("/chat.Chat/Echo")
  let _ = call.send(b"one")
  let _ = call.close_send()
  match call.close_send() {
    Ok(_) => fail("second close_send must not succeed")
    Err(s) => assert_eq(s == @moonrpc.Status::Cancelled, true)
  }
}
