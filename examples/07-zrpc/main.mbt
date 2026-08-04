///|
/// Register a zRPC service with all four cardinalities and drive real gRPC calls
/// through the in-process h2c channel — unary, server-streaming, client-streaming,
/// and bidirectional — plus the trailers-only UNIMPLEMENTED an unknown method
/// answers with.
///
///     moon run examples/07-zrpc
#coverage.skip
fn main {
  try {
    // Config loads from the same YAML go-zero's zrpc.RpcServerConf reads.
    let conf = @moonzero.RpcServerConf::from_yaml("name: greeter\nport: 9090\n")
    let rpc = @moonzero.RpcServer::new(conf)
    let g = rpc.group("hello.Greeter")
    g.register("SayHello", req => enc("hello " + dec(req)))
    g.register_server_streaming("Tail", req => {
      [enc("chunk-1: " + dec(req)), enc("chunk-2: " + dec(req))]
    })
    g.register_client_streaming("Upload", msgs => {
      enc("received " + msgs.length().to_string() + " parts")
    })
    g.register_bidi_streaming("Chat", () => @moonzero.BidiStreamHandler::{
      on_message: m => [enc("re: " + dec(m))],
      on_end: () => [enc("bye")],
    })
    println("service " + rpc.conf().name + " methods: " + methods_of(rpc))
    println(
      "has SayHello: " + rpc.has_method("/hello.Greeter/SayHello").to_string(),
    )

    // dispatch is the transport-free view of the unary registry.
    println(
      "dispatch SayHello -> " +
      unary(rpc.dispatch("/hello.Greeter/SayHello", enc("qwe"))),
    )
    println(
      "dispatch unknown -> " +
      unary(rpc.dispatch("/hello.Greeter/Nope", enc("x"))),
    )

    // Real h2c round-trips over the channel.
    let ch = @moonzero.RpcChannel::connect(rpc)
    println(
      "unary  -> " + unary(ch.call("/hello.Greeter/SayHello", enc("lfanke"))),
    )
    println(
      "server -> " +
      stream(ch.call_server_streaming("/hello.Greeter/Tail", enc("emm"))),
    )
    println(
      "client -> " +
      unary(
        ch.call_client_streaming("/hello.Greeter/Upload", [
          enc("a"),
          enc("b"),
          enc("c"),
        ]),
      ),
    )

    // Interactive bidi: each send returns the replies produced right then; close_send
    // half-closes and runs on_end.
    let call = ch.open_bidi("/hello.Greeter/Chat")
    println("bidi send hhh -> " + join(call.send(enc("hhh")).map(dec)))
    println("bidi send qwq -> " + join(call.send(enc("qwq")).map(dec)))
    println("bidi close -> " + stream(call.close_send()))

    // One-shot bidi driving the whole exchange.
    println(
      "bidi one-shot -> " +
      stream(
        ch.call_bidi_streaming("/hello.Greeter/Chat", [enc("1"), enc("2")]),
      ),
    )

    // An unregistered path answers UNIMPLEMENTED — the trailers-only response a gRPC
    // server sends for an unknown method.
    println(
      "unknown path -> " + unary(ch.call("/hello.Greeter/Missing", enc("x"))),
    )
    println("status_of_code(12) = " + @moonzero.status_of_code(12).name())
  } catch {
    _ => println("unexpected transport error")
  }
}

///|
fn methods_of(rpc : @moonzero.RpcServer) -> String {
  let ms = rpc.methods()
  ms.sort()
  join(ms)
}

///|
fn unary(r : Result[Bytes, @moonrpc.Status]) -> String {
  match r {
    Ok(b) => "ok(" + dec(b) + ")"
    Err(s) => "err(" + s.name() + ")"
  }
}

///|
fn stream(r : Result[Array[Bytes], @moonrpc.Status]) -> String {
  match r {
    Ok(msgs) => "ok" + join(msgs.map(dec))
    Err(s) => "err(" + s.name() + ")"
  }
}

///|
fn enc(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
fn dec(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
fn join(items : Array[String]) -> String {
  let sb = StringBuilder::new()
  sb.write_char('[')
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(items[i])
  }
  sb.write_char(']')
  sb.to_string()
}
