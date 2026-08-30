// What a registration does when its lease lapses. A real etcd will not expire a
// lease on demand, so the interesting case is unreachable against a live server —
// which is why `Publisher` takes a seam rather than the socket.

///|
/// An etcd that hands out leases, forgets one when told to, and records everything
/// it was asked to do.
struct FakeKeeper {
  mut next_lease : Int64
  mut expired : Bool
  granted : Array[Int64]
  puts : Array[(Bytes, Int64)]
  renewals : Array[Int64]
  forgotten : Array[Bytes]
}

///|
fn FakeKeeper::new() -> FakeKeeper {
  {
    next_lease: 100L,
    expired: false,
    granted: [],
    puts: [],
    renewals: [],
    forgotten: [],
  }
}

///|
impl @discov.LeaseKeeper for FakeKeeper with fn grant(self, _ttl) {
  self.next_lease = self.next_lease + 1L
  self.granted.push(self.next_lease)
  self.next_lease
}

///|
impl @discov.LeaseKeeper for FakeKeeper with fn put(self, key, _value, lease) {
  self.puts.push((key, lease))
}

///|
/// A renewal answers the remaining TTL, and zero once the lease has been dropped —
/// which is how etcd reports that renewing it renews nothing.
impl @discov.LeaseKeeper for FakeKeeper with fn renew(self, lease) {
  self.renewals.push(lease)
  if self.expired {
    self.expired = false
    0L
  } else {
    10L
  }
}

///|
impl @discov.LeaseKeeper for FakeKeeper with fn forget(self, key) {
  self.forgotten.push(key)
}

///|
/// Registering takes a lease and writes the key under it.
async test "a publisher registers under a lease" {
  @async.with_task_group(_g => {
    let fake = FakeKeeper::new()
    let pub_ = @discov.Publisher::start(
      fake, b"moonzero/greet/1", b"127.0.0.1:8080",
    )
    assert_eq(fake.granted, [101L])
    assert_eq(fake.puts.length(), 1)
    assert_eq(fake.puts[0].1, 101L)
    assert_eq(pub_.lease_id(), 101L)
  })
}

///|
/// A lapsed lease is the case that matters: renewing a dead lease renews nothing, so
/// the publisher has to take a new one and register again. Without this the instance
/// disappears from discovery and nothing anywhere says so.
async test "a publisher re-registers when its lease has expired" {
  @async.with_task_group(g => {
    let fake = FakeKeeper::new()
    let pub_ = @discov.Publisher::start(
      fake,
      b"moonzero/greet/1",
      b"127.0.0.1:8080",
      ttl=1L,
    )
    fake.expired = true
    let task = g.spawn(() => pub_.keep_alive())
    // One renewal is enough to see the recovery; the interval is a third of the TTL.
    @async.sleep(900)
    pub_.halt()
    task.cancel()
    assert_eq(fake.renewals.length() > 0, true)
    assert_eq(fake.renewals[0], 101L)
    // The dead lease was replaced and the key written again under the new one.
    assert_eq(fake.granted, [101L, 102L])
    assert_eq(fake.puts.length(), 2)
    assert_eq(fake.puts[1].1, 102L)
    assert_eq(pub_.lease_id(), 102L)
  })
}

///|
/// Stopping leaves discovery now rather than at the end of the TTL.
async test "stopping deletes the key" {
  @async.with_task_group(_g => {
    let fake = FakeKeeper::new()
    let pub_ = @discov.Publisher::start(
      fake, b"moonzero/greet/1", b"1.2.3.4:80",
    )
    pub_.stop()
    assert_eq(fake.forgotten, [b"moonzero/greet/1"])
  })
}
