// Reference vectors produced by CPython's `protobuf` (6.33) compiling the etcd
// `etcdserverpb` KV messages, so the self-built encoders must match the exact bytes a
// real etcd server produces and reads.

///|
fn etcd_nib(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else {
    c.to_int() - 'A'.to_int() + 10
  }
}

///|
fn etcd_unhex(s : String) -> Bytes {
  let buf = Buffer()
  let chars = s.to_array()
  let mut i = 0
  while i + 1 < chars.length() {
    buf.write_byte(
      ((etcd_nib(chars[i]) << 4) | etcd_nib(chars[i + 1])).to_byte(),
    )
    i += 2
  }
  buf.to_bytes()
}

///|
test "etcd RangeRequest encodes to the exact protobuf bytes protobuf produces" {
  let req : EtcdRangeRequest = { key: b"foo", range_end: b"fop", limit: 100 }
  // protobuf: RangeRequest(key="foo", range_end="fop", limit=100)
  assert_eq(req.encode() == etcd_unhex("0a03666f6f1203666f701864"), true)
  assert_eq(EtcdRangeRequest::decode(req.encode()) == req, true)
}

///|
test "etcd KeyValue encodes to the exact protobuf bytes and round-trips" {
  let kv : EtcdKeyValue = {
    key: b"k",
    create_revision: 2,
    mod_revision: 3,
    version: 1,
    value: b"v",
    lease: 7,
  }
  // protobuf: KeyValue(key="k", create_revision=2, mod_revision=3, version=1,
  // value="v", lease=7)
  assert_eq(kv.encode() == etcd_unhex("0a016b1002180320012a01763007"), true)
  assert_eq(EtcdKeyValue::decode(kv.encode()) == kv, true)
}

///|
test "etcd PutRequest encodes to the exact protobuf bytes and round-trips" {
  let put : EtcdPutRequest = { key: b"k", value: b"v", lease: 7 }
  // protobuf: PutRequest(key="k", value="v", lease=7)
  assert_eq(put.encode() == etcd_unhex("0a016b1201761807"), true)
  assert_eq(EtcdPutRequest::decode(put.encode()) == put, true)
}

///|
test "etcd RangeResponse carries nested KeyValues and a count through a round-trip" {
  let resp : EtcdRangeResponse = {
    kvs: [
      { ..EtcdKeyValue::empty(), key: b"a", value: b"1", mod_revision: 5 },
      { ..EtcdKeyValue::empty(), key: b"b", value: b"2", mod_revision: 6 },
    ],
    count: 2,
  }
  let decoded = EtcdRangeResponse::decode(resp.encode())
  assert_eq(decoded.count, 2)
  assert_eq(decoded.kvs.length(), 2)
  assert_eq(decoded.kvs[0].key == b"a", true)
  assert_eq(decoded.kvs[1].mod_revision, 6)
  assert_eq(decoded == resp, true)
}

///|
test "etcd default (empty/zero) fields are omitted, per proto3" {
  // A RangeRequest for a single key with no range_end or limit encodes only field 1.
  let req : EtcdRangeRequest = { key: b"x", range_end: b"", limit: 0 }
  assert_eq(req.encode() == etcd_unhex("0a0178"), true)
}

///|
test "etcd Lease messages encode to the exact protobuf bytes and round-trip" {
  let grant : EtcdLeaseGrantRequest = { ttl: 60, id: 1234 }
  assert_eq(grant.encode() == etcd_unhex("083c10d209"), true)
  assert_eq(EtcdLeaseGrantRequest::decode(grant.encode()) == grant, true)
  let granted : EtcdLeaseGrantResponse = { id: 1234, ttl: 60, error: "" }
  assert_eq(granted.encode() == etcd_unhex("10d209183c"), true)
  assert_eq(EtcdLeaseGrantResponse::decode(granted.encode()) == granted, true)
  let ka : EtcdLeaseKeepAliveRequest = { id: 1234 }
  assert_eq(ka.encode() == etcd_unhex("08d209"), true)
  assert_eq(EtcdLeaseKeepAliveRequest::decode(ka.encode()) == ka, true)
  let kar : EtcdLeaseKeepAliveResponse = { id: 1234, ttl: 59 }
  assert_eq(kar.encode() == etcd_unhex("10d209183b"), true)
  assert_eq(EtcdLeaseKeepAliveResponse::decode(kar.encode()) == kar, true)
}

///|
test "etcd watch Event encodes to the exact protobuf bytes, PUT vs DELETE" {
  // A PUT event carries the full key/value; type PUT (0) is the proto3 default so it
  // is omitted from the wire.
  let put : EtcdEvent = {
    event_type: Put,
    kv: {
      ..EtcdKeyValue::empty(),
      key: b"svc/a",
      value: b"1.2.3.4",
      mod_revision: 9,
    },
  }
  assert_eq(
    put.encode() == etcd_unhex("12120a057376632f6118092a07312e322e332e34"),
    true,
  )
  assert_eq(EtcdEvent::decode(put.encode()) == put, true)
  // A DELETE event writes the type explicitly and just the key.
  let del : EtcdEvent = {
    event_type: Delete,
    kv: { ..EtcdKeyValue::empty(), key: b"svc/a" },
  }
  assert_eq(del.encode() == etcd_unhex("080112070a057376632f61"), true)
  let decoded = EtcdEvent::decode(del.encode())
  assert_eq(decoded.event_type == Delete, true)
  assert_eq(decoded.kv.key == b"svc/a", true)
}
