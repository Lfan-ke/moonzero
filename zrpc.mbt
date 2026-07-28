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
) -> RpcChannel raise {
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
/// Allocate the next client stream id and send the request HEADERS (the gRPC
/// pseudo-headers + `content-type`/`te`), returning the id and any frames the engine
/// emitted right away — an unregistered path answers with its trailers-only
/// UNIMPLEMENTED during this HEADERS feed, before any DATA. Client-initiated streams
/// use odd identifiers advancing by two (RFC 7540 §5.1.1).
fn RpcChannel::open(
  self : RpcChannel,
  path : String,
) -> (Int, Array[@moonrpc.Frame]) raise {
  let sid = self.next_stream_id
  self.next_stream_id = self.next_stream_id + 2
  let block = self.encoder.encode([
    { name: b":method", value: b"POST" },
    { name: b":scheme", value: b"http" },
    { name: b":path", value: ascii_bytes(path) },
    { name: b":authority", value: ascii_bytes(self.authority) },
    { name: b"content-type", value: b"application/grpc" },
    { name: b"te", value: b"trailers" },
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
) -> Array[@moonrpc.Frame] raise {
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
