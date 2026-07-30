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

///|
/// A `WatchCreateRequest`: subscribe to changes on `key`, or on the half-open range
/// `[key, range_end)`, from `start_revision` (0 = current). A discovery watcher opens
/// one over the service's key prefix.
pub(all) struct EtcdWatchCreateRequest {
  key : Bytes
  range_end : Bytes
  start_revision : Int64
} derive(Eq)

///|
/// Encode a `WatchCreateRequest` (key=1, range_end=2, start_revision=3).
pub fn EtcdWatchCreateRequest::encode(self : EtcdWatchCreateRequest) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.key.length() > 0 {
    w.bytes_(1, self.key)
  }
  if self.range_end.length() > 0 {
    w.bytes_(2, self.range_end)
  }
  if self.start_revision != 0 {
    w.int64(3, self.start_revision)
  }
  w.to_bytes()
}

///|
/// Decode a `WatchCreateRequest`.
pub fn EtcdWatchCreateRequest::decode(
  data : Bytes,
) -> EtcdWatchCreateRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut key = b""
  let mut range_end = b""
  let mut start_revision = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => key = r.read_bytes()
      2 => range_end = r.read_bytes()
      3 => start_revision = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { key, range_end, start_revision }
}

///|
/// A `WatchCancelRequest`: stop the watch stream identified by `watch_id`.
pub(all) struct EtcdWatchCancelRequest {
  watch_id : Int64
} derive(Eq)

///|
/// Encode a `WatchCancelRequest` (watch_id=1).
pub fn EtcdWatchCancelRequest::encode(self : EtcdWatchCancelRequest) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.watch_id != 0 {
    w.int64(1, self.watch_id)
  }
  w.to_bytes()
}

///|
/// Decode a `WatchCancelRequest`.
pub fn EtcdWatchCancelRequest::decode(
  data : Bytes,
) -> EtcdWatchCancelRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut watch_id = 0L
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => watch_id = r.read_int64()
      _ => r.skip(wire)
    }
  }
  { watch_id, }
}

///|
/// A `WatchRequest`, the `request_union` oneof of the bidi Watch stream: either a
/// `Create` to open a watch or a `Cancel` to close one.
pub(all) enum EtcdWatchRequest {
  Create(EtcdWatchCreateRequest)
  Cancel(EtcdWatchCancelRequest)
} derive(Eq)

///|
/// Encode a `WatchRequest` (create_request=1, cancel_request=2).
pub fn EtcdWatchRequest::encode(self : EtcdWatchRequest) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  match self {
    Create(c) => w.message_(1, c.encode())
    Cancel(c) => w.message_(2, c.encode())
  }
  w.to_bytes()
}

///|
/// Decode a `WatchRequest`; the last-set oneof arm wins, defaulting to an empty
/// `Create`.
pub fn EtcdWatchRequest::decode(
  data : Bytes,
) -> EtcdWatchRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut result : EtcdWatchRequest = Create({
    key: b"",
    range_end: b"",
    start_revision: 0,
  })
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => result = Create(EtcdWatchCreateRequest::decode(r.read_bytes()))
      2 => result = Cancel(EtcdWatchCancelRequest::decode(r.read_bytes()))
      _ => r.skip(wire)
    }
  }
  result
}

///|
/// A `WatchResponse`: the server-assigned `watch_id`, the `created` / `canceled`
/// lifecycle flags, and the batch of change `events` since the last response. A
/// discovery watcher folds each event into add/remove of a service instance.
pub(all) struct EtcdWatchResponse {
  watch_id : Int64
  created : Bool
  canceled : Bool
  events : Array[EtcdEvent]
} derive(Eq)

///|
/// Encode a `WatchResponse` (watch_id=2, created=3, canceled=4, events=11 repeated).
pub fn EtcdWatchResponse::encode(self : EtcdWatchResponse) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.watch_id != 0 {
    w.int64(2, self.watch_id)
  }
  if self.created {
    w.bool_(3, self.created)
  }
  if self.canceled {
    w.bool_(4, self.canceled)
  }
  for ev in self.events {
    w.message_(11, ev.encode())
  }
  w.to_bytes()
}

///|
/// Decode a `WatchResponse`.
pub fn EtcdWatchResponse::decode(
  data : Bytes,
) -> EtcdWatchResponse raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut watch_id = 0L
  let mut created = false
  let mut canceled = false
  let events : Array[EtcdEvent] = []
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      2 => watch_id = r.read_int64()
      3 => created = r.read_bool()
      4 => canceled = r.read_bool()
      11 => events.push(EtcdEvent::decode(r.read_bytes()))
      _ => r.skip(wire)
    }
  }
  { watch_id, created, canceled, events }
}

///|
/// A `DeleteRangeRequest`: delete the key at `key`, or the half-open range
/// `[key, range_end)`; `prev_kv` asks the server to return the deleted key/values. A
/// discovery client sends this to deregister an instance.
pub(all) struct EtcdDeleteRangeRequest {
  key : Bytes
  range_end : Bytes
  prev_kv : Bool
} derive(Eq)

///|
/// Encode a `DeleteRangeRequest` (key=1, range_end=2, prev_kv=3).
pub fn EtcdDeleteRangeRequest::encode(self : EtcdDeleteRangeRequest) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.key.length() > 0 {
    w.bytes_(1, self.key)
  }
  if self.range_end.length() > 0 {
    w.bytes_(2, self.range_end)
  }
  if self.prev_kv {
    w.bool_(3, self.prev_kv)
  }
  w.to_bytes()
}

///|
/// Decode a `DeleteRangeRequest`.
pub fn EtcdDeleteRangeRequest::decode(
  data : Bytes,
) -> EtcdDeleteRangeRequest raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut key = b""
  let mut range_end = b""
  let mut prev_kv = false
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      1 => key = r.read_bytes()
      2 => range_end = r.read_bytes()
      3 => prev_kv = r.read_bool()
      _ => r.skip(wire)
    }
  }
  { key, range_end, prev_kv }
}

///|
/// A `DeleteRangeResponse`: the number of keys `deleted` and, when `prev_kv` was
/// requested, the `prev_kvs` that were removed.
pub(all) struct EtcdDeleteRangeResponse {
  deleted : Int64
  prev_kvs : Array[EtcdKeyValue]
} derive(Eq)

///|
/// Encode a `DeleteRangeResponse` (deleted=2, prev_kvs=3 repeated).
pub fn EtcdDeleteRangeResponse::encode(self : EtcdDeleteRangeResponse) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.deleted != 0 {
    w.int64(2, self.deleted)
  }
  for kv in self.prev_kvs {
    w.message_(3, kv.encode())
  }
  w.to_bytes()
}

///|
/// Decode a `DeleteRangeResponse`.
pub fn EtcdDeleteRangeResponse::decode(
  data : Bytes,
) -> EtcdDeleteRangeResponse raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut deleted = 0L
  let prev_kvs : Array[EtcdKeyValue] = []
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      2 => deleted = r.read_int64()
      3 => prev_kvs.push(EtcdKeyValue::decode(r.read_bytes()))
      _ => r.skip(wire)
    }
  }
  { deleted, prev_kvs }
}

///|
/// A `PutResponse`: when `prev_kv` was requested on the `PutRequest`, the key/value
/// that the put replaced (its key is empty when there was none).
pub(all) struct EtcdPutResponse {
  prev_kv : EtcdKeyValue
} derive(Eq)

///|
/// Encode a `PutResponse` (prev_kv=2); an absent previous value (empty key) is omitted.
pub fn EtcdPutResponse::encode(self : EtcdPutResponse) -> Bytes {
  let w = @moonrpc.PbWriter::new()
  if self.prev_kv.key.length() > 0 {
    w.message_(2, self.prev_kv.encode())
  }
  w.to_bytes()
}

///|
/// Decode a `PutResponse`.
pub fn EtcdPutResponse::decode(
  data : Bytes,
) -> EtcdPutResponse raise @moonrpc.PbError {
  let r = @moonrpc.PbReader::new(data)
  let mut prev_kv = EtcdKeyValue::empty()
  while !r.eof() {
    let (field, wire) = r.read_tag()
    match field {
      2 => prev_kv = EtcdKeyValue::decode(r.read_bytes())
      _ => r.skip(wire)
    }
  }
  { prev_kv, }
}
