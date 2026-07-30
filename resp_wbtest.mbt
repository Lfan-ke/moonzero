// RESP codec byte vectors, taken straight from the Redis protocol specification. The
// encoder's output is checked byte-for-byte against the frame a real redis client
// sends, and every RESP2 and RESP3 reply shape decodes back to the expected value —
// the same bytes a real redis writes on the wire.

///|
test "resp encode: command as an array of bulk strings" {
  assert_eq(resp_command(["PING"]), b"*1\r\n$4\r\nPING\r\n")
  assert_eq(
    resp_command(["SET", "k", "v"]),
    b"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n",
  )
  // Binary-safe arguments round-trip unchanged (a NUL byte in a value).
  assert_eq(
    resp_encode_command([b"GET", b"\x00\x01"]),
    b"*2\r\n$3\r\nGET\r\n$2\r\n\x00\x01\r\n",
  )
}

///|
test "resp decode: RESP2 simple types" {
  assert_eq(RespValue::decode(b"+OK\r\n"), SimpleString("OK"))
  assert_eq(
    RespValue::decode(b"-ERR bad request\r\n"),
    Error("ERR bad request"),
  )
  assert_eq(RespValue::decode(b":1000\r\n"), Integer(1000))
  assert_eq(RespValue::decode(b":-5\r\n"), Integer(-5))
}

///|
test "resp decode: RESP2 bulk strings and null" {
  assert_eq(RespValue::decode(b"$5\r\nhello\r\n"), BulkString(b"hello"))
  assert_eq(RespValue::decode(b"$0\r\n\r\n"), BulkString(b""))
  // A bulk string may hold CRLF and binary bytes; the length governs, not a delimiter.
  assert_eq(RespValue::decode(b"$3\r\na\r\n\r\n"), BulkString(b"a\r\n"))
  assert_eq(RespValue::decode(b"$-1\r\n"), Null)
}

///|
test "resp decode: RESP2 arrays, null array, empty array" {
  assert_eq(
    RespValue::decode(b"*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"),
    Array([BulkString(b"foo"), BulkString(b"bar")]),
  )
  // A null array (`*-1`) is distinct from an empty array (`*0`).
  assert_eq(RespValue::decode(b"*-1\r\n"), Null)
  assert_eq(RespValue::decode(b"*0\r\n"), Array([]))
  // Nested: an array holding an integer and a bulk string.
  assert_eq(
    RespValue::decode(b"*2\r\n:1\r\n$2\r\nhi\r\n"),
    Array([Integer(1), BulkString(b"hi")]),
  )
}

///|
test "resp decode: RESP3 null, boolean, big number" {
  assert_eq(RespValue::decode(b"_\r\n"), Null)
  assert_eq(RespValue::decode(b"#t\r\n"), Boolean(true))
  assert_eq(RespValue::decode(b"#f\r\n"), Boolean(false))
  assert_eq(
    RespValue::decode(b"(3492890328409238509324850943850943825024385\r\n"),
    BigNumber("3492890328409238509324850943850943825024385"),
  )
}

///|
test "resp decode: RESP3 doubles including inf and nan" {
  assert_eq(RespValue::decode(b",3.14\r\n"), Double(3.14))
  assert_eq(RespValue::decode(b",10\r\n"), Double(10.0))
  assert_eq(RespValue::decode(b",inf\r\n"), Double(@double.infinity))
  assert_eq(RespValue::decode(b",-inf\r\n"), Double(@double.neg_infinity))
  // NaN never equals itself, so match the shape rather than compare values.
  match RespValue::decode(b",nan\r\n") {
    Double(d) => assert_eq(d != d, true)
    _ => abort("expected a double")
  }
}

///|
test "resp decode: RESP3 bulk error and verbatim string" {
  assert_eq(
    RespValue::decode(b"!21\r\nSYNTAX invalid syntax\r\n"),
    BulkError("SYNTAX invalid syntax"),
  )
  assert_eq(
    RespValue::decode(b"=15\r\ntxt:Some string\r\n"),
    VerbatimString("txt", b"Some string"),
  )
}

///|
test "resp decode: RESP3 map, set, push" {
  assert_eq(
    RespValue::decode(b"%2\r\n+key1\r\n:1\r\n+key2\r\n:2\r\n"),
    RespMap([
      (SimpleString("key1"), Integer(1)),
      (SimpleString("key2"), Integer(2)),
    ]),
  )
  assert_eq(
    RespValue::decode(b"~2\r\n+a\r\n+b\r\n"),
    RespSet([SimpleString("a"), SimpleString("b")]),
  )
  assert_eq(
    RespValue::decode(b">2\r\n$7\r\nmessage\r\n$2\r\nhi\r\n"),
    Push([BulkString(b"message"), BulkString(b"hi")]),
  )
}

///|
test "resp reader: pipelined replies decode in sequence" {
  let reader = RespReader::new(b"+A\r\n:2\r\n$1\r\nx\r\n")
  assert_eq(reader.read(), SimpleString("A"))
  assert_eq(reader.read(), Integer(2))
  assert_eq(reader.read(), BulkString(b"x"))
  assert_eq(reader.at_end(), true)
}

///|
test "resp decode: malformed frames raise" {
  // A bulk length longer than the available bytes.
  let truncated = try {
    let _ = RespValue::decode(b"$5\r\nhi\r\n")
    false
  } catch {
    _ => true
  }
  assert_eq(truncated, true)
  // A line with no terminating CRLF.
  let unterminated = try {
    let _ = RespValue::decode(b"+OK")
    false
  } catch {
    _ => true
  }
  assert_eq(unterminated, true)
  // An unknown type marker.
  let unknown = try {
    let _ = RespValue::decode(b"@nope\r\n")
    false
  } catch {
    _ => true
  }
  assert_eq(unknown, true)
  // Trailing bytes after a complete value.
  let trailing = try {
    let _ = RespValue::decode(b"+OK\r\n:1\r\n")
    false
  } catch {
    _ => true
  }
  assert_eq(trailing, true)
}
