///|
test "generated ids have the right hex width and are deterministic" {
  let t = generate_trace_id(1L)
  assert_eq(t.length(), 32)
  assert_eq(is_hex(t, 32), true)
  let s = generate_span_id(1L)
  assert_eq(s.length(), 16)
  assert_eq(is_hex(s, 16), true)
  // same seed -> same id; different seed -> different id
  assert_eq(generate_trace_id(1L), t)
  assert_eq(generate_trace_id(2L) != t, true)
  assert_eq(generate_span_id(1L) != generate_span_id(2L), true)
}

///|
test "trace context formats as a W3C traceparent" {
  let ctx = {
    trace_id: "0af7651916cd43dd8448eb211c80319c",
    span_id: "b7ad6b7169203331",
    flags: 1,
  }
  assert_eq(
    ctx.to_traceparent(),
    "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
  )
  assert_eq(ctx.trace_id(), "0af7651916cd43dd8448eb211c80319c")
  assert_eq(ctx.span_id(), "b7ad6b7169203331")
}

///|
test "parse_traceparent round-trips a valid header and rejects malformed ones" {
  let raw = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  match parse_traceparent(raw) {
    Some(ctx) => {
      assert_eq(ctx.trace_id, "0af7651916cd43dd8448eb211c80319c")
      assert_eq(ctx.span_id, "b7ad6b7169203331")
      assert_eq(ctx.flags, 1)
      // a parsed context re-emits the same header
      assert_eq(ctx.to_traceparent(), raw)
    }
    None => fail("valid traceparent should parse")
  }
  // wrong field count
  assert_eq(parse_traceparent("00-abc-01") is None, true)
  // trace-id too short
  assert_eq(parse_traceparent("00-0af7-b7ad6b7169203331-01") is None, true)
  // span-id not hex
  assert_eq(
    parse_traceparent("00-0af7651916cd43dd8448eb211c80319c-zzzzzzzzzzzzzzzz-01")
    is None,
    true,
  )
  // empty
  assert_eq(parse_traceparent("") is None, true)
}

///|
test "next_trace_context continues an inbound trace and mints a child span" {
  let parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  let ctx = next_trace_context(Some(parent), 7L)
  // the trace id is carried through unchanged...
  assert_eq(ctx.trace_id, "0af7651916cd43dd8448eb211c80319c")
  // ...but the span id is a fresh child, not the parent's
  assert_eq(ctx.span_id != "b7ad6b7169203331", true)
  assert_eq(ctx.span_id, generate_span_id(7L))
}

///|
test "next_trace_context starts a new trace when none inbound or malformed" {
  let fresh = next_trace_context(None, 3L)
  assert_eq(fresh.trace_id, generate_trace_id(3L))
  assert_eq(fresh.span_id, generate_span_id(3L))
  assert_eq(fresh.flags, 1)
  // a malformed inbound header is treated as no context: a new trace starts
  let bad = next_trace_context(Some("garbage"), 4L)
  assert_eq(bad.trace_id, generate_trace_id(4L))
}

///|
test "tracing middleware assembles into an AsgiApp" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let _ = tracing()(app.to_asgi())
}
