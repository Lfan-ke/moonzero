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
