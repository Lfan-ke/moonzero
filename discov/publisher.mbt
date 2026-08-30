// Keeping a registration alive (← go-zero `core/discov.Publisher`). A lease grant is
// the easy half: without something renewing it, every registered instance vanishes
// from discovery the moment its TTL runs out, and nothing anywhere reports that it
// did. This is the half that renews.

///|
/// The four etcd calls a registration needs. A trait rather than the concrete socket
/// because the interesting behaviour — what happens when a lease lapses — cannot be
/// provoked against a real server on demand, and a registration that silently stops
/// existing is exactly the failure worth testing.
pub(open) trait LeaseKeeper {
  async fn grant(Self, ttl : Int64) -> Int64
  async fn put(Self, key : Bytes, value : Bytes, lease : Int64) -> Unit
  async fn renew(Self, lease : Int64) -> Int64
  async fn forget(Self, key : Bytes) -> Unit
}

///|
/// `EtcdSocket` speaking that contract.
pub impl LeaseKeeper for EtcdSocket with fn grant(self, ttl) {
  self.lease_grant(@moonzero.EtcdLeaseGrantRequest::{ ttl, id: 0L, }).id
}

///|
pub impl LeaseKeeper for EtcdSocket with fn put(self, key, value, lease) {
  let _ = self.put(@moonzero.EtcdPutRequest::{ key, value, lease, })
}

///|
pub impl LeaseKeeper for EtcdSocket with fn renew(self, lease) {
  self.lease_keep_alive(@moonzero.EtcdLeaseKeepAliveRequest::{ id: lease, }).ttl
}

///|
pub impl LeaseKeeper for EtcdSocket with fn forget(self, key) {
  let _ = self.delete_range(@moonzero.EtcdDeleteRangeRequest::{
    key,
    range_end: b"",
    prev_kv: false,
  })
}

///|
/// A registration that stays registered: the key, its value, the lease behind it,
/// and the renewal loop that keeps that lease from lapsing.
pub struct Publisher {
  socket : &LeaseKeeper
  key : Bytes
  value : Bytes
  ttl : Int64
  mut lease : Int64
  mut stopped : Bool
}

///|
/// Register `key` = `value` under a fresh lease and hand back the publisher that
/// owns it. Nothing is renewed until `keep_alive` runs — start that in its own task.
///
/// `ttl` is in seconds, matching etcd, and defaults to go-zero's ten.
pub async fn Publisher::start(
  socket : &LeaseKeeper,
  key : Bytes,
  value : Bytes,
  ttl? : Int64 = 10L,
) -> Publisher {
  let lease = socket.grant(ttl)
  socket.put(key, value, lease)
  { socket, key, value, ttl, lease, stopped: false, }
}

///|
/// Renew the lease until `stop` is called, sleeping a third of the TTL between
/// renewals so two can be lost before the registration is.
///
/// A renewal answering `ttl: 0` means the lease is already gone — a partition
/// outlasted it, say — and renewing a dead lease renews nothing, so the key is
/// registered again under a fresh one. That recovery is the reason this loop exists
/// rather than a bare timer.
pub async fn Publisher::keep_alive(self : Publisher) -> Unit {
  let interval = (self.ttl * 1000L / 3L).to_int()
  while !self.stopped {
    @async.sleep(if interval < 1 { 1 } else { interval })
    if self.stopped {
      return
    }
    let remaining = self.socket.renew(self.lease)
    if remaining == 0L {
      self.revive()
    }
  }
}

///|
/// Take a fresh lease and re-register under it, after the old one expired.
async fn Publisher::revive(self : Publisher) -> Unit {
  self.lease = self.socket.grant(self.ttl)
  self.socket.put(self.key, self.value, self.lease)
}

///|
/// Stop renewing and delete the key, so the instance leaves discovery now rather
/// than at the end of its TTL. The lease is left to expire on its own — etcd drops
/// it, and a revoke would be one more call that can fail on the way out.
pub async fn Publisher::stop(self : Publisher) -> Unit {
  self.stopped = true
  self.socket.forget(self.key)
}

///|
/// Stop the renewal loop without deleting the key — for a caller that is shutting
/// the process down and would rather let the lease lapse than race a delete against
/// a closing connection.
pub fn Publisher::halt(self : Publisher) -> Unit {
  self.stopped = true
}

///|
/// The lease this registration currently rides on. It changes when a lapsed lease
/// is revived, which is what a test asserts against.
pub fn Publisher::lease_id(self : Publisher) -> Int64 {
  self.lease
}
