// The etcd v3 KV RPC message layer (`etcdserverpb`), the first foundation of a real
// etcd network client for service discovery (← go-zero's `discov`, which talks to a
// live etcd over gRPC). The messages are self-built on moonrpc's protobuf runtime —
// the same `PbWriter` / `PbReader` the gRPC transport uses — with the field numbers
// fixed by etcd's `rpc.proto`, so a `KeyValue` / `RangeRequest` / `PutRequest` encodes
// byte-for-byte to what a real etcd server expects. The gRPC calls over an
// `@moonrpc.Channel` build on top of this.

///|
/// An etcd `KeyValue` (`mvccpb.KeyValue`): a key, its value, the create/mod revisions
/// and version that track its history, and the lease it is attached to.
pub(all) struct EtcdKeyValue {
  key : Bytes
  create_revision : Int64
  mod_revision : Int64
  version : Int64
  value : Bytes
  lease : Int64
} derive(Eq)

///|
/// The empty key/value with all-zero metadata.
pub fn EtcdKeyValue::empty() -> EtcdKeyValue {
  {
    key: b"",
    create_revision: 0,
    mod_revision: 0,
    version: 0,
    value: b"",
    lease: 0,
  }
}

///|
/// Encode a `KeyValue` to its protobuf wire bytes (field numbers per etcd
/// `mvccpb.proto`: key=1, create_revision=2, mod_revision=3, version=4, value=5,
/// lease=6). Proto3 default (empty / zero) fields are omitted.
pub fn EtcdKeyValue::encode(self : EtcdKeyValue) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.key.length() > 0 {
    w.bytes_(1, self.key)
  }
  if self.create_revision != 0 {
    w.int64(2, self.create_revision)
  }
  if self.mod_revision != 0 {
    w.int64(3, self.mod_revision)
  }
  if self.version != 0 {
    w.int64(4, self.version)
  }
  if self.value.length() > 0 {
    w.bytes_(5, self.value)
  }
  if self.lease != 0 {
    w.int64(6, self.lease)
  }
  w.to_bytes()
}

///|
/// Decode a `KeyValue` from protobuf wire bytes; unknown fields are skipped.
pub fn EtcdKeyValue::decode(
  data : Bytes,
) -> EtcdKeyValue raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut key = b""
  let mut create_revision = 0L
  let mut mod_revision = 0L
  let mut version = 0L
  let mut value = b""
  let mut lease = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => key = r.read_bytes()
      2 => create_revision = r.read_int64()
      3 => mod_revision = r.read_int64()
      4 => version = r.read_int64()
      5 => value = r.read_bytes()
      6 => lease = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { key, create_revision, mod_revision, version, value, lease }
}

///|
/// A `RangeRequest` (`etcdserverpb`): read the key at `key`, or the half-open range
/// `[key, range_end)` when `range_end` is set, up to `limit` results (0 = no limit).
pub(all) struct EtcdRangeRequest {
  key : Bytes
  range_end : Bytes
  limit : Int64
} derive(Eq)

///|
/// Encode a `RangeRequest` (key=1, range_end=2, limit=3).
pub fn EtcdRangeRequest::encode(self : EtcdRangeRequest) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.key.length() > 0 {
    w.bytes_(1, self.key)
  }
  if self.range_end.length() > 0 {
    w.bytes_(2, self.range_end)
  }
  if self.limit != 0 {
    w.int64(3, self.limit)
  }
  w.to_bytes()
}

///|
/// Decode a `RangeRequest`.
pub fn EtcdRangeRequest::decode(
  data : Bytes,
) -> EtcdRangeRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut key = b""
  let mut range_end = b""
  let mut limit = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => key = r.read_bytes()
      2 => range_end = r.read_bytes()
      3 => limit = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { key, range_end, limit }
}

///|
/// A `RangeResponse`: the matched key/values and the total `count` in the range (which
/// may exceed the returned `kvs` when a `limit` capped them).
pub(all) struct EtcdRangeResponse {
  kvs : Array[EtcdKeyValue]
  count : Int64
} derive(Eq)

///|
/// Encode a `RangeResponse` (kvs=2 repeated, count=4).
pub fn EtcdRangeResponse::encode(self : EtcdRangeResponse) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  for kv in self.kvs {
    w.message_(2, kv.encode())
  }
  if self.count != 0 {
    w.int64(4, self.count)
  }
  w.to_bytes()
}

///|
/// Decode a `RangeResponse`; each `kvs` entry is a nested `KeyValue` message.
pub fn EtcdRangeResponse::decode(
  data : Bytes,
) -> EtcdRangeResponse raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let kvs : Array[EtcdKeyValue] = []
  let mut count = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      2 => kvs.push(EtcdKeyValue::decode(r.read_bytes()))
      4 => count = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { kvs, count }
}

///|
/// A `PutRequest`: store `value` at `key`, optionally under `lease`.
pub(all) struct EtcdPutRequest {
  key : Bytes
  value : Bytes
  lease : Int64
} derive(Eq)

///|
/// Encode a `PutRequest` (key=1, value=2, lease=3).
pub fn EtcdPutRequest::encode(self : EtcdPutRequest) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.key.length() > 0 {
    w.bytes_(1, self.key)
  }
  if self.value.length() > 0 {
    w.bytes_(2, self.value)
  }
  if self.lease != 0 {
    w.int64(3, self.lease)
  }
  w.to_bytes()
}

///|
/// Decode a `PutRequest`.
pub fn EtcdPutRequest::decode(
  data : Bytes,
) -> EtcdPutRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut key = b""
  let mut value = b""
  let mut lease = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => key = r.read_bytes()
      2 => value = r.read_bytes()
      3 => lease = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { key, value, lease }
}

///|
/// A `LeaseGrantRequest`: ask etcd for a lease living `ttl` seconds (`id` 0 lets the
/// server assign one). A registered service key attaches to the lease and vanishes
/// when the lease expires — go-zero's instance liveness mechanism.
pub(all) struct EtcdLeaseGrantRequest {
  ttl : Int64
  id : Int64
} derive(Eq)

///|
/// Encode a `LeaseGrantRequest` (TTL=1, ID=2).
pub fn EtcdLeaseGrantRequest::encode(self : EtcdLeaseGrantRequest) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.ttl != 0 {
    w.int64(1, self.ttl)
  }
  if self.id != 0 {
    w.int64(2, self.id)
  }
  w.to_bytes()
}

///|
/// Decode a `LeaseGrantRequest`.
pub fn EtcdLeaseGrantRequest::decode(
  data : Bytes,
) -> EtcdLeaseGrantRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut ttl = 0L
  let mut id = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => ttl = r.read_int64()
      2 => id = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { ttl, id }
}

///|
/// A `LeaseGrantResponse`: the granted lease `id`, its actual `ttl`, and an `error`
/// string when the grant failed.
pub(all) struct EtcdLeaseGrantResponse {
  id : Int64
  ttl : Int64
  error : String
} derive(Eq)

///|
/// Encode a `LeaseGrantResponse` (ID=2, TTL=3, error=4).
pub fn EtcdLeaseGrantResponse::encode(self : EtcdLeaseGrantResponse) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.id != 0 {
    w.int64(2, self.id)
  }
  if self.ttl != 0 {
    w.int64(3, self.ttl)
  }
  if self.error.length() > 0 {
    w.string_(4, self.error)
  }
  w.to_bytes()
}

///|
/// Decode a `LeaseGrantResponse`.
pub fn EtcdLeaseGrantResponse::decode(
  data : Bytes,
) -> EtcdLeaseGrantResponse raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut id = 0L
  let mut ttl = 0L
  let mut error = ""
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      2 => id = r.read_int64()
      3 => ttl = r.read_int64()
      4 => error = r.read_string()
      _ => r.skip(wire)
    }
  }
  { id, ttl, error }
}

///|
/// A `LeaseKeepAliveRequest`: renew lease `id` before it expires. A discovery client
/// streams these to keep its instance registered.
pub(all) struct EtcdLeaseKeepAliveRequest {
  id : Int64
} derive(Eq)

///|
/// Encode a `LeaseKeepAliveRequest` (ID=1).
pub fn EtcdLeaseKeepAliveRequest::encode(
  self : EtcdLeaseKeepAliveRequest,
) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.id != 0 {
    w.int64(1, self.id)
  }
  w.to_bytes()
}

///|
/// Decode a `LeaseKeepAliveRequest`.
pub fn EtcdLeaseKeepAliveRequest::decode(
  data : Bytes,
) -> EtcdLeaseKeepAliveRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut id = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => id = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { id, }
}

///|
/// A `LeaseKeepAliveResponse`: the renewed lease `id` and its remaining `ttl` (0 =
/// the lease has expired).
pub(all) struct EtcdLeaseKeepAliveResponse {
  id : Int64
  ttl : Int64
} derive(Eq)

///|
/// Encode a `LeaseKeepAliveResponse` (ID=2, TTL=3).
pub fn EtcdLeaseKeepAliveResponse::encode(
  self : EtcdLeaseKeepAliveResponse,
) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.id != 0 {
    w.int64(2, self.id)
  }
  if self.ttl != 0 {
    w.int64(3, self.ttl)
  }
  w.to_bytes()
}

///|
/// Decode a `LeaseKeepAliveResponse`.
pub fn EtcdLeaseKeepAliveResponse::decode(
  data : Bytes,
) -> EtcdLeaseKeepAliveResponse raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut id = 0L
  let mut ttl = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      2 => id = r.read_int64()
      3 => ttl = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { id, ttl }
}

///|
/// The kind of change a watch `Event` reports (`mvccpb.Event.EventType`): a key was
/// `Put` (created or updated) or `Delete`d.
pub(all) enum EtcdEventType {
  Put
  Delete
} derive(Eq)

///|
/// The protobuf enum number of an event type (`PUT` = 0, `DELETE` = 1).
pub fn EtcdEventType::to_int(self : EtcdEventType) -> Int {
  match self {
    Put => 0
    Delete => 1
  }
}

///|
/// The event type for a protobuf enum number; unknown numbers read as `Put`.
pub fn EtcdEventType::from_int(n : Int) -> EtcdEventType {
  if n == 1 {
    Delete
  } else {
    Put
  }
}

///|
/// A watch `Event` (`mvccpb.Event`): a change to one key, carrying the resulting
/// `KeyValue` (for a delete, the key with cleared metadata). This is what a discovery
/// watcher folds into add/remove of a service instance.
pub(all) struct EtcdEvent {
  event_type : EtcdEventType
  kv : EtcdKeyValue
} derive(Eq)

///|
/// Encode an `Event` (type=1, kv=2). `PUT` (0) is the proto3 default and omitted.
pub fn EtcdEvent::encode(self : EtcdEvent) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.event_type.to_int() != 0 {
    w.int32(1, self.event_type.to_int())
  }
  w.message_(2, self.kv.encode())
  w.to_bytes()
}

///|
/// Decode an `Event`.
pub fn EtcdEvent::decode(data : Bytes) -> EtcdEvent raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut event_type = EtcdEventType::Put
  let mut kv = EtcdKeyValue::empty()
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => event_type = EtcdEventType::from_int(r.read_int32())
      2 => kv = EtcdKeyValue::decode(r.read_bytes())
      _ => r.skip(wire)
    }
  }
  { event_type, kv }
}
