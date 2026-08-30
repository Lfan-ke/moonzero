///|
/// How a call recorded in a `Window` ended (← the `success`/`fail`/`drop`
/// markers go-zero's breaker writes into its window). A `Drop` is a call that
/// was shed before it ran: traffic, but neither a success nor a failure of
/// whatever is downstream.
pub(all) enum Outcome {
  Succ
  Fail
  Drop
} derive(Eq, Debug)

///|
/// One time slice of a `Window`. `sum` counts every call that landed in the
/// slice including the shed ones, so a slice being throttled still reads as
/// busy rather than idle.
pub struct Bucket {
  mut sum : Int64
  mut succ : Int64
  mut fail : Int64
  mut drop : Int64
}

///|
fn Bucket::add(self : Bucket, o : Outcome) -> Unit {
  self.sum = self.sum + 1L
  match o {
    Succ => self.succ = self.succ + 1L
    Fail => self.fail = self.fail + 1L
    Drop => self.drop = self.drop + 1L
  }
}

///|
fn Bucket::reset(self : Bucket) -> Unit {
  self.sum = 0L
  self.succ = 0L
  self.fail = 0L
  self.drop = 0L
}

///|
/// A rolling window of `size` buckets covering `bucket_ms` milliseconds each
/// (← go-zero's `collection.RollingWindow`), which is how the breaker reads a
/// backend's recent health: forty 250ms slices, so the last ten seconds and
/// nothing older.
///
/// Time never moves on its own — every call carries the `now` it happens at, as
/// the other resilience cores here do. Writing at a later `now` clears the
/// buckets the gap swept past before recording; reading at a later `now` skips
/// them without clearing, so a window nobody writes to still ages out, and two
/// reads at the same `now` agree.
pub struct Window {
  size : Int
  bucket_ms : Int64
  buckets : Array[Bucket]
  mut offset : Int
  mut bucket_start : Int64
}

///|
/// An empty window of `size` buckets of `bucket_ms` each, its first bucket
/// starting at `now`. The defaults are go-zero's ten seconds in forty slices. A
/// size or duration below one is raised to one, the way the other cores here
/// clamp their bounds rather than rejecting them.
pub fn Window::new(
  size? : Int = 40,
  bucket_ms? : Int64 = 250L,
  now? : Int64 = 0L,
) -> Window {
  let size = if size < 1 { 1 } else { size }
  let bucket_ms = if bucket_ms < 1L { 1L } else { bucket_ms }
  {
    size,
    bucket_ms,
    buckets: Array::makei(size, _ => Bucket::{
      sum: 0L,
      succ: 0L,
      fail: 0L,
      drop: 0L,
    }),
    offset: 0,
    bucket_start: now,
  }
}

///|
/// How many buckets have elapsed since the head bucket opened, capped at `size`
/// because beyond that the whole window is stale. A clock that moves backwards
/// counts as no elapsed time.
fn Window::span(self : Window, now : Int64) -> Int {
  let n = (now - self.bucket_start) / self.bucket_ms
  if n <= 0L {
    0
  } else if n < self.size.to_int64() {
    n.to_int()
  } else {
    self.size
  }
}

///|
/// Move the write cursor to `now`, clearing the buckets the gap swept past. The
/// new head is snapped back to a `bucket_ms` boundary, so buckets keep their
/// exact width instead of drifting with the arrival time of each call.
fn Window::advance(self : Window, now : Int64) -> Unit {
  let span = self.span(now)
  if span <= 0 {
    return
  }
  for i in 0..<span {
    self.buckets[(self.offset + i + 1) % self.size].reset()
  }
  self.offset = (self.offset + span) % self.size
  self.bucket_start = now - (now - self.bucket_start) % self.bucket_ms
}

///|
/// Record one call ending as `o` at time `now`.
pub fn Window::add(self : Window, o : Outcome, now : Int64) -> Unit {
  self.advance(now)
  self.buckets[self.offset].add(o)
}

///|
/// Visit the buckets still inside the window at `now`, oldest first (← go-zero's
/// `Reduce`). Stale buckets are skipped, not cleared: reading leaves the window
/// exactly as it was.
pub fn Window::each(self : Window, now : Int64, f : (Bucket) -> Unit) -> Unit {
  let span = self.span(now)
  let live = self.size - span
  if live <= 0 {
    return
  }
  let head = (self.offset + span + 1) % self.size
  for i in 0..<live {
    f(self.buckets[(head + i) % self.size])
  }
}
