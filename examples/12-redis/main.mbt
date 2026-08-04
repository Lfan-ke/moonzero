///|
/// The RESP wire codec the redis discovery driver rides on: encode a command as a
/// RESP array of bulk strings, decode every RESP2 and RESP3 reply shape back into a
/// `RespValue`, stream several pipelined replies through a `RespReader`, and build
/// the discovery keys. The `RedisClient`/`RedisDiscovery` layer that carries these
/// bytes over a socket rides a sealed `RedisConn` transport (exercised by the
/// in-repo white-box tests — see the note in the examples README).
///
///     moon run examples/12-redis
#coverage.skip
fn main {
  try {
    // A command goes out as an array of bulk strings, one per argument.
    let cmd = @moonzero.resp_command(["SET", "greeter/1", "10.0.0.1:9090"])
    println("resp_command SET -> " + escape(@utf8.decode_lossy(cmd[:])))
    let cmd2 = @moonzero.resp_encode_command([b"GET", b"greeter/1"])
    println("resp_encode_command GET -> " + escape(@utf8.decode_lossy(cmd2[:])))

    // Every reply shape decodes back to a RespValue; resp_kind names its type.
    for
      frame in [
        b"+OK\r\n", b":233\r\n", b"$8\r\nheke1228\r\n", b"_\r\n", b"#t\r\n", b",3.14\r\n",
        b"*2\r\n:1\r\n$3\r\nqwq\r\n", b"%1\r\n+role\r\n$6\r\nmaster\r\n",
      ] {
      let value = @moonzero.RespValue::decode(frame)
      println(
        "decode " +
        escape(@utf8.decode_lossy(frame[:])) +
        " -> " +
        resp_show(value) +
        " [" +
        @moonzero.resp_kind(value) +
        "]",
      )
    }

    // A reader decodes several pipelined replies in sequence.
    let reader = @moonzero.RespReader::new(b"+PONG\r\n:66666\r\n")
    let a = reader.read()
    let b = reader.read()
    println(
      "pipelined -> " +
      resp_show(a) +
      ", " +
      resp_show(b) +
      " at_end=" +
      reader.at_end().to_string(),
    )

    // The discovery keys an instance is registered under and scanned by.
    let ep = @moonzero.Endpoint::new("10.0.0.1", 9090)
    println(
      "service prefix: " +
      @moonzero.redis_service_prefix("moonzero/", "greeter"),
    )
    println(
      "instance key:   " +
      @moonzero.redis_instance_key("moonzero/", "greeter", ep),
    )
    println(
      "scan pattern:   " +
      @moonzero.redis_service_pattern("moonzero/", "greeter"),
    )
  } catch {
    RespError(msg) => println("resp error: " + msg)
  }
}

///|
fn resp_show(v : @moonzero.RespValue) -> String {
  match v {
    SimpleString(s) => "simple(" + s + ")"
    Error(s) => "error(" + s + ")"
    Integer(n) => "int(" + n.to_string() + ")"
    BulkString(bytes) => "bulk(" + @utf8.decode_lossy(bytes[:]) + ")"
    Null => "null"
    Boolean(x) => "bool(" + x.to_string() + ")"
    Double(d) => "double(" + d.to_string() + ")"
    Array(items) => "array" + join(items.map(resp_show))
    RespMap(pairs) =>
      "map" + join(pairs.map(p => resp_show(p.0) + "=" + resp_show(p.1)))
    other => @moonzero.resp_kind(other)
  }
}

///|
/// Render a wire string with its CRLF framing visible.
fn escape(s : String) -> String {
  let sb = StringBuilder::new()
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == '\r' {
      sb.write_string("\\r")
    } else if c == '\n' {
      sb.write_string("\\n")
    } else {
      sb.write_char(c.to_int().unsafe_to_char())
    }
  }
  sb.to_string()
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
