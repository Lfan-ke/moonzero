///|
/// ASCII/latin-1 `String` to `Bytes`, one octet per code unit. HTTP/2 pseudo-header
/// values (`:path`, `:authority`) and gRPC paths are ASCII, so this is exact.
fn ascii_bytes(s : String) -> Bytes {
  let buf = Buffer()
  for i = 0; i < s.length(); i = i + 1 {
    buf.write_byte((s[i].to_int() & 0xFF).to_byte())
  }
  buf.to_bytes()
}

///|
/// Parse an ASCII decimal byte string (a `grpc-status` header value) as an `Int`.
/// A non-digit octet or an empty value yields `-1`, which maps to `Unknown`.
fn parse_ascii_int(b : Bytes) -> Int {
  if b.length() == 0 {
    return -1
  }
  let mut n = 0
  for i = 0; i < b.length(); i = i + 1 {
    let d = b[i].to_int() - 0x30
    if d < 0 || d > 9 {
      return -1
    }
    n = n * 10 + d
  }
  n
}

///|
/// The value of the first `@moonrpc.Header` whose name equals the ASCII `name`,
/// or `None`.
fn h2_header_value(headers : Array[@moonrpc.Header], name : String) -> Bytes? {
  let want = ascii_bytes(name)
  for h in headers {
    if h.name == want {
      return Some(h.value)
    }
  }
  None
}

///|
/// Map a numeric `grpc-status` code back to a `@moonrpc.Status`. Anything outside
/// the canonical 0–16 range is reported as `Unknown`, matching how a gRPC client
/// treats an unrecognised code.
pub fn status_of_code(code : Int) -> @moonrpc.Status {
  match code {
    0 => Ok
    1 => Cancelled
    2 => Unknown
    3 => InvalidArgument
    4 => DeadlineExceeded
    5 => NotFound
    6 => AlreadyExists
    7 => PermissionDenied
    8 => ResourceExhausted
    9 => FailedPrecondition
    10 => Aborted
    11 => OutOfRange
    12 => Unimplemented
    13 => Internal
    14 => Unavailable
    15 => DataLoss
    16 => Unauthenticated
    _ => Unknown
  }
}

///|
/// Build a `@moonrpc.H2Server` protocol engine from this zRPC server's registered
/// handlers — the transport-facing view of the same registry `dispatch` reads.
/// Each handler is bound to its gRPC path, so a request arriving over the h2c
/// transport is dispatched to exactly the handler the group registered.
pub fn RpcServer::to_h2(self : RpcServer) -> @moonrpc.H2Server {
  let engine = @moonrpc.H2Server::new()
  for path, handler in self.handlers {
    engine.register(path, req => handler(req))
  }
  for path, handler in self.server_streaming {
    engine.register_server_streaming(path, (_ctx, req) => handler(req))
  }
  for path, handler in self.client_streaming {
    engine.register_client_streaming(path, (_ctx, msgs) => handler(msgs))
  }
  for path, factory in self.bidi_streaming {
    engine.register_bidi(path, _ctx => {
      let h = factory()
      { on_message: h.on_message, on_end: h.on_end, }
    })
  }
  engine
}

///|
/// An in-process gRPC channel bound to a server engine — the client half of the
/// h2c transport. A call is carried as the real HTTP/2 frames a socket-backed
/// client would send: an HPACK-coded HEADERS block with the gRPC pseudo-headers,
/// a length-prefixed DATA frame closing the stream, and the `grpc-status` trailer
/// read back off the engine's reply. The channel's HPACK encoder pairs with the
/// engine's decoder and vice versa, so the dynamic-table state stays in lockstep
/// across every call on the channel.
pub struct RpcChannel {
  engine : @moonrpc.H2Server
  encoder : @moonrpc.HpackEncoder
  decoder : @moonrpc.HpackDecoder
  authority : String
  mut next_stream_id : Int
}

///|
/// Open a channel to `server` over an in-process h2c transport, exchanging the
/// opening SETTINGS the way a real connection does. Client-initiated streams use
/// odd identifiers (RFC 7540 §5.1.1), starting at 1.
pub fn RpcChannel::connect(
  server : RpcServer,
  authority? : String = "localhost",
) -> RpcChannel {
  let engine = server.to_h2()
  let ch = {
    engine,
    encoder: @moonrpc.HpackEncoder::new(),
    decoder: @moonrpc.HpackDecoder::new(),
    authority,
    next_stream_id: 1,
  }
  // Client connection preface SETTINGS; the ack is consumed and discarded.
  let _ = engine.feed(Settings(params=[], ack=false))
  ch
}

///|
/// Invoke a unary method at `path` with `request` as its message payload, driving
/// the call through the h2c engine and returning the reply payload on
/// `grpc-status: 0`, or the mapped `@moonrpc.Status` otherwise. `request` and the
/// returned reply are bare message bytes; the length-prefix framing is applied
/// and stripped by the transport.
pub fn RpcChannel::call(
  self : RpcChannel,
  path : String,
  request : Bytes,
) -> Result[Bytes, @moonrpc.Status] raise {
  let (sid, frames) = self.open(path)
  for f in self.feed_data(sid, @moonrpc.encode_message(request), true) {
    frames.push(f)
  }
  match self.collect_reply(sid, frames) {
    (code, msgs) =>
      match status_of_code(code) {
        Ok => Ok(if msgs.length() > 0 { msgs[0] } else { b"" })
        other => Err(other)
      }
  }
}

///|
/// Invoke a server-streaming method at `path`: send the single request message and
/// read back the ordered sequence of reply messages the server produced, or the
/// mapped error `@moonrpc.Status` if the stream closed with a non-zero
/// `grpc-status`. On `Ok` the array holds every message in emission order (possibly
/// empty).
pub fn RpcChannel::call_server_streaming(
  self : RpcChannel,
  path : String,
  request : Bytes,
) -> Result[Array[Bytes], @moonrpc.Status] raise {
  let (sid, frames) = self.open(path)
  for f in self.feed_data(sid, @moonrpc.encode_message(request), true) {
    frames.push(f)
  }
  match self.collect_reply(sid, frames) {
    (code, msgs) =>
      match status_of_code(code) {
        Ok => Ok(msgs)
        other => Err(other)
      }
  }
}

///|
/// Invoke a client-streaming method at `path`: send every message in `requests`
/// as its own DATA frame, half-close the stream, and read back the single reply.
/// An empty `requests` still opens and half-closes the stream, so the handler runs
/// with no messages.
pub fn RpcChannel::call_client_streaming(
  self : RpcChannel,
  path : String,
  requests : Array[Bytes],
) -> Result[Bytes, @moonrpc.Status] raise {
  let (sid, frames) = self.open(path)
  if requests.length() == 0 {
    for f in self.feed_data(sid, b"", true) {
      frames.push(f)
    }
  } else {
    for i = 0; i < requests.length(); i = i + 1 {
      let last = i == requests.length() - 1
      for f in self.feed_data(sid, @moonrpc.encode_message(requests[i]), last) {
        frames.push(f)
      }
    }
  }
  match self.collect_reply(sid, frames) {
    (code, msgs) =>
      match status_of_code(code) {
        Ok => Ok(if msgs.length() > 0 { msgs[0] } else { b"" })
        other => Err(other)
      }
  }
}

///|
/// A live client-side bidirectional call over the h2c channel (← gRPC's
/// `ClientStream`): the request stream stays open while messages flow both ways.
/// `send` writes one request message and returns whatever replies the server
/// produced right then (bidi interleaving — an echo handler answers each message
/// as it arrives); `close_send` half-closes the request stream, runs the server's
/// `on_end`, and reports the final `grpc-status`. The channel's HPACK decoder is
/// advanced across every reply block, so its dynamic table stays in lockstep with
/// the engine's encoder for the life of the call. `pending` holds DATA octets not
/// yet split into a whole length-prefixed message (a message may straddle two DATA
/// frames under flow control).
pub struct BidiCall {
  channel : RpcChannel
  sid : Int
  mut pending : Bytes
  mut status_code : Int
  mut ended : Bool
}

///|
/// Open a bidirectional stream to `path`, sending the request HEADERS without
/// half-closing so the stream stays open for interleaved `send`s. An unregistered
/// path answers trailers-only UNIMPLEMENTED during this HEADERS feed, which the
/// returned call captures as its status.
pub fn RpcChannel::open_bidi(
  self : RpcChannel,
  path : String,
) -> BidiCall raise {
  let (sid, frames) = self.open(path)
  let call = {
    channel: self,
    sid,
    pending: b"",
    status_code: -1,
    ended: false,
  }
  let _ = call.absorb(frames)
  call
}

///|
/// Fold a batch of reply frames into the call: HPACK-decode every HEADERS block
/// for this stream (keeping the decoder's dynamic table in sync and picking up
/// `grpc-status` when it appears), append this stream's DATA to `pending`, and
/// return the reply messages that are now complete, leaving any partial tail
/// buffered.
fn BidiCall::absorb(
  self : BidiCall,
  frames : Array[@moonrpc.Frame],
) -> Array[Bytes] raise {
  let acc = Buffer()
  acc.write_bytes(self.pending)
  for f in frames {
    match f {
      Headers(stream_id~, fragment~, ..) =>
        if stream_id == self.sid {
          let headers = self.channel.decoder.decode(fragment)
          match h2_header_value(headers, "grpc-status") {
            Some(v) => self.status_code = parse_ascii_int(v)
            None => ()
          }
        }
      Data(stream_id~, data~, ..) =>
        if stream_id == self.sid {
          acc.write_bytes(data)
        }
      _ => ()
    }
  }
  let (msgs, rest) = drain_messages(acc.to_bytes())
  self.pending = rest
  msgs
}

///|
/// Send one request message on the open stream and return the replies the server
/// emitted in response to it (possibly empty). A no-op once the stream is
/// half-closed.
pub fn BidiCall::send(self : BidiCall, msg : Bytes) -> Array[Bytes] raise {
  guard !self.ended else { return [] }
  let frames = self.channel.feed_data(
    self.sid,
    @moonrpc.encode_message(msg),
    false,
  )
  self.absorb(frames)
}

///|
/// Half-close the request stream: run the server's `on_end`, return its final
/// reply messages, and map the `grpc-status` trailer to `Ok`/`Err`. Calling it a
/// second time is an error (`Cancelled`).
pub fn BidiCall::close_send(
  self : BidiCall,
) -> Result[Array[Bytes], @moonrpc.Status] raise {
  guard !self.ended else { return Err(@moonrpc.Status::Cancelled) }
  self.ended = true
  let frames = self.channel.feed_data(self.sid, b"", true)
  let msgs = self.absorb(frames)
  match status_of_code(self.status_code) {
    Ok => Ok(msgs)
    other => Err(other)
  }
}

///|
/// Drive a whole bidirectional call at `path` in one shot: send every message in
/// `requests` (collecting the interleaved replies in order), then half-close and
/// append the `on_end` replies. The result is every reply message the server
/// produced, in emission order, or the non-zero `grpc-status` the stream closed
/// with.
pub fn RpcChannel::call_bidi_streaming(
  self : RpcChannel,
  path : String,
  requests : Array[Bytes],
) -> Result[Array[Bytes], @moonrpc.Status] raise {
  let call = self.open_bidi(path)
  let out : Array[Bytes] = []
  for r in requests {
    for m in call.send(r) {
      out.push(m)
    }
  }
  match call.close_send() {
    Ok(final_msgs) => {
      for m in final_msgs {
        out.push(m)
      }
      Ok(out)
    }
    Err(status) => Err(status)
  }
}

///|
/// Split a run of concatenated gRPC length-prefixed messages into their payloads,
/// returning the complete messages and any trailing partial-message octets that
/// have not yet arrived in full. Like `decode_all_messages` but surfaces the
/// remainder so a streaming caller can carry it across DATA frames.
fn drain_messages(body : Bytes) -> (Array[Bytes], Bytes) {
  let out : Array[Bytes] = []
  let n = body.length()
  let mut off = 0
  while n - off >= 5 {
    let len = (body[off + 1].to_int() << 24) |
      (body[off + 2].to_int() << 16) |
      (body[off + 3].to_int() << 8) |
      body[off + 4].to_int()
    if n - off < 5 + len {
      break
    }
    out.push(body[off + 5:off + 5 + len].to_owned())
    off = off + 5 + len
  }
  (out, body[off:n].to_owned())
}

///|
/// Allocate the next client stream id and send the request HEADERS (the gRPC
/// pseudo-headers + `content-type`/`te`), returning the id and any frames the engine
/// emitted right away — an unregistered path answers with its trailers-only
/// UNIMPLEMENTED during this HEADERS feed, before any DATA. Client-initiated streams
/// use odd identifiers advancing by two (RFC 7540 §5.1.1).
fn RpcChannel::open(
  self : RpcChannel,
  path : String,
) -> (Int, Array[@moonrpc.Frame]) {
  let sid = self.next_stream_id
  self.next_stream_id = self.next_stream_id + 2
  let block = self.encoder.encode([
    { name: b":method", value: b"POST", },
    { name: b":scheme", value: b"http", },
    { name: b":path", value: ascii_bytes(path), },
    { name: b":authority", value: ascii_bytes(self.authority), },
    { name: b"content-type", value: b"application/grpc", },
    { name: b"te", value: b"trailers", },
  ])
  let frames = self.engine.feed(
    Headers(
      stream_id=sid,
      fragment=block,
      end_stream=false,
      end_headers=true,
      priority=None,
      padding=0,
    ),
  )
  (sid, frames)
}

///|
/// Feed one DATA frame carrying `payload` on stream `sid`, half-closing the stream
/// when `end` is set, and return the reply frames the engine emitted.
fn RpcChannel::feed_data(
  self : RpcChannel,
  sid : Int,
  payload : Bytes,
  end : Bool,
) -> Array[@moonrpc.Frame] {
  self.engine.feed(Data(stream_id=sid, data=payload, end_stream=end, padding=0))
}

///|
/// Decode the engine's reply frames for stream `sid`: concatenate DATA payloads,
/// HPACK-decode every HEADERS block in arrival order (keeping the decoder's
/// dynamic table in sync) to find `grpc-status`, then split the body into its
/// length-prefixed messages. Returns the status code (`-1`, i.e. `Unknown`, when no
/// `grpc-status` was seen) and the decoded messages in order.
fn RpcChannel::collect_reply(
  self : RpcChannel,
  sid : Int,
  frames : Array[@moonrpc.Frame],
) -> (Int, Array[Bytes]) raise {
  let body = Buffer()
  let mut status_code : Int = -1
  for f in frames {
    match f {
      Headers(stream_id~, fragment~, ..) =>
        if stream_id == sid {
          let headers = self.decoder.decode(fragment)
          match h2_header_value(headers, "grpc-status") {
            Some(v) => status_code = parse_ascii_int(v)
            None => ()
          }
        }
      Data(stream_id~, data~, ..) =>
        if stream_id == sid {
          body.write_bytes(data)
        }
      _ => ()
    }
  }
  (status_code, decode_all_messages(body.to_bytes()))
}

///|
/// Split a run of concatenated gRPC length-prefixed messages into their payloads,
/// stopping at the first truncated frame. Each message is a 1-byte compression flag
/// plus a 4-byte big-endian length plus that many payload octets.
fn decode_all_messages(body : Bytes) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let n = body.length()
  let mut off = 0
  while n - off >= 5 {
    let len = (body[off + 1].to_int() << 24) |
      (body[off + 2].to_int() << 16) |
      (body[off + 3].to_int() << 8) |
      body[off + 4].to_int()
    if n - off < 5 + len {
      break
    }
    out.push(body[off + 5:off + 5 + len].to_owned())
    off = off + 5 + len
  }
  out
}
