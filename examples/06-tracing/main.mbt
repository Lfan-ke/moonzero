///|
/// The W3C Trace Context propagation decision the `tracing` middleware makes: start
/// a fresh trace when there is no inbound `traceparent`, continue the inbound
/// trace id (with a fresh child span) when there is a valid one, and reject a
/// malformed header.
///
///     moon run examples/06-tracing
#coverage.skip
fn main {
  // No inbound header: a brand-new trace and span.
  let fresh = @moonzero.next_trace_context(None, 233L)
  println("new trace: " + fresh.to_traceparent())
  println("  trace_id=" + fresh.trace_id() + " span_id=" + fresh.span_id())

  // A valid inbound traceparent: the trace id is carried through, a new child span
  // is minted for this hop.
  let inbound = fresh.to_traceparent()
  let child = @moonzero.next_trace_context(Some(inbound), 23333L)
  println("continued trace: " + child.to_traceparent())
  println(
    "  same trace_id as parent: " +
    (child.trace_id() == fresh.trace_id()).to_string(),
  )
  println(
    "  fresh child span: " + (child.span_id() != fresh.span_id()).to_string(),
  )

  // A malformed inbound header is ignored and a new trace is started instead.
  let recovered = @moonzero.next_trace_context(
    Some("not-a-traceparent"),
    66666L,
  )
  println("malformed inbound -> new trace_id: " + recovered.trace_id())

  // parse_traceparent accepts the canonical shape and rejects everything else.
  match @moonzero.parse_traceparent(inbound) {
    Some(ctx) => println("parsed span: " + ctx.span_id())
    None => println("parse failed")
  }
  println(
    "parse garbage -> " +
    (@moonzero.parse_traceparent("00-xyz") is None).to_string(),
  )

  // The raw id generators the propagation is built on.
  println(
    "trace_id(seed=233): " +
    @moonzero.generate_trace_id(233L) +
    " span_id(seed=233): " +
    @moonzero.generate_span_id(233L),
  )
}
