// The etcd v3 KV/Lease/Watch gRPC service calls, layered on the etcdserverpb messages
// and moonzero's `RpcChannel` (the h2c gRPC client that carries the real HTTP/2 frames
// through the transport). This is the network client go-zero's `discov` runs against a
// live etcd: `range` to list a prefix, `put` under a lease to register, `delete_range`
// to deregister, `lease_grant` for the instance TTL, and `watch` to stream changes.

///|
/// An etcd gRPC call that returned a non-OK `grpc-status`.
pub suberror EtcdError {
  EtcdError(String)
}

///|
/// An etcd v3 client bound to a gRPC channel (real etcd, or a mock server in tests).
pub struct EtcdClient {
  channel : RpcChannel
}

///|
/// An etcd client over `channel`.
pub fn EtcdClient::new(channel : RpcChannel) -> EtcdClient {
  { channel, }
}

///|
/// Turn a unary reply into decoded bytes, mapping a non-OK status to `EtcdError`.
fn etcd_unwrap(
  result : Result[Bytes, @moonrpc.Status],
  call_name : String,
) -> Bytes raise EtcdError {
  match result {
    Ok(reply) => reply
    Err(status) =>
      raise EtcdError(call_name + " failed: " + @moonrpc.Status::name(status))
  }
}

///|
/// `KV.Range`: read the key or prefix range in `req`.
pub fn EtcdClient::range(
  self : EtcdClient,
  req : EtcdRangeRequest,
) -> EtcdRangeResponse raise {
  EtcdRangeResponse::decode(
    etcd_unwrap(
      self.channel.call("/etcdserverpb.KV/Range", req.encode()),
      "Range",
    ),
  )
}

///|
/// `KV.Put`: store the key/value (optionally under a lease) in `req`.
pub fn EtcdClient::put(
  self : EtcdClient,
  req : EtcdPutRequest,
) -> EtcdPutResponse raise {
  EtcdPutResponse::decode(
    etcd_unwrap(self.channel.call("/etcdserverpb.KV/Put", req.encode()), "Put"),
  )
}

///|
/// `KV.DeleteRange`: delete the key or range in `req` (deregister).
pub fn EtcdClient::delete_range(
  self : EtcdClient,
  req : EtcdDeleteRangeRequest,
) -> EtcdDeleteRangeResponse raise {
  EtcdDeleteRangeResponse::decode(
    etcd_unwrap(
      self.channel.call("/etcdserverpb.KV/DeleteRange", req.encode()),
      "DeleteRange",
    ),
  )
}

///|
/// `Lease.LeaseGrant`: obtain a lease with the requested TTL.
pub fn EtcdClient::lease_grant(
  self : EtcdClient,
  req : EtcdLeaseGrantRequest,
) -> EtcdLeaseGrantResponse raise {
  EtcdLeaseGrantResponse::decode(
    etcd_unwrap(
      self.channel.call("/etcdserverpb.Lease/LeaseGrant", req.encode()),
      "LeaseGrant",
    ),
  )
}

///|
/// `Watch.Watch`: open a watch with `req` and read the stream of responses the server
/// produces (etcd's Watch is a bidi stream; this drives the common open-then-observe
/// direction over the server-streaming path). Each `WatchResponse` carries the batch
/// of change events since the last one.
pub fn EtcdClient::watch(
  self : EtcdClient,
  req : EtcdWatchRequest,
) -> Array[EtcdWatchResponse] raise {
  let replies = match
    self.channel.call_server_streaming(
      "/etcdserverpb.Watch/Watch",
      req.encode(),
    ) {
    Ok(msgs) => msgs
    Err(status) =>
      raise EtcdError("Watch failed: " + @moonrpc.Status::name(status))
  }
  let out : Array[EtcdWatchResponse] = []
  for reply in replies {
    out.push(EtcdWatchResponse::decode(reply))
  }
  out
}
