// etcd's KV/Lease gRPC calls over a real TCP socket: the network client go-zero's
// discov runs against a live etcd. moonzero's root `EtcdClient` drives its calls over
// the in-process `RpcChannel` (all backends, no socket); this native-only path drives
// the same etcdserverpb messages over moonrpc's real h2c `@net.Channel` — one long-
// lived multiplexed HTTP/2 connection over the socket — reusing the root's etcd message
// codec unchanged. Native-only, because `moonbitlang/async` has no JS/Wasm backend.

///|
/// An etcd gRPC call that returned a non-OK `grpc-status`.
pub suberror EtcdSocketError {
  EtcdSocketError(String)
}

///|
/// A live etcd v3 client over a real gRPC socket connection.
pub struct EtcdSocket {
  channel : @net.Channel
}

///|
/// Open a gRPC connection to the etcd at `host:port` (etcd serves client gRPC on 2379).
pub async fn EtcdSocket::connect(host : String, port : Int) -> EtcdSocket {
  { channel: @net.Channel::connect(host, port) }
}

///|
/// Close the connection.
pub fn EtcdSocket::close(self : EtcdSocket) -> Unit {
  self.channel.close()
}

///|
/// Make a unary call, returning the single reply message on `grpc-status: 0` or raising
/// on any other status.
async fn EtcdSocket::unary_bytes(
  self : EtcdSocket,
  path : String,
  request : Bytes,
) -> Bytes {
  let reply = self.channel.unary(path, request)
  if reply.grpc_status != 0 {
    raise EtcdSocketError(
      path + " -> grpc-status " + reply.grpc_status.to_string(),
    )
  }
  if reply.messages.length() == 0 {
    b""
  } else {
    reply.messages[0]
  }
}

///|
/// `KV.Range`: read the key or prefix range in `req`.
pub async fn EtcdSocket::range(
  self : EtcdSocket,
  req : @moonzero.EtcdRangeRequest,
) -> @moonzero.EtcdRangeResponse {
  @moonzero.EtcdRangeResponse::decode(
    self.unary_bytes("/etcdserverpb.KV/Range", req.encode()),
  )
}

///|
/// `KV.Put`: store the key/value (optionally under a lease) in `req`.
pub async fn EtcdSocket::put(
  self : EtcdSocket,
  req : @moonzero.EtcdPutRequest,
) -> @moonzero.EtcdPutResponse {
  @moonzero.EtcdPutResponse::decode(
    self.unary_bytes("/etcdserverpb.KV/Put", req.encode()),
  )
}

///|
/// `KV.DeleteRange`: delete the key or range in `req` (deregister).
pub async fn EtcdSocket::delete_range(
  self : EtcdSocket,
  req : @moonzero.EtcdDeleteRangeRequest,
) -> @moonzero.EtcdDeleteRangeResponse {
  @moonzero.EtcdDeleteRangeResponse::decode(
    self.unary_bytes("/etcdserverpb.KV/DeleteRange", req.encode()),
  )
}

///|
/// `Lease.LeaseGrant`: obtain a lease with the requested TTL.
pub async fn EtcdSocket::lease_grant(
  self : EtcdSocket,
  req : @moonzero.EtcdLeaseGrantRequest,
) -> @moonzero.EtcdLeaseGrantResponse {
  @moonzero.EtcdLeaseGrantResponse::decode(
    self.unary_bytes("/etcdserverpb.Lease/LeaseGrant", req.encode()),
  )
}
