///|
/// The four counters summed over whatever is still live in the window at `now`.
priv struct Sums {
  mut sum : Int64
  mut succ : Int64
  mut fail : Int64
  mut drop : Int64
}

///|
fn sums(w : Window, now : Int64) -> Sums {
  let s = Sums::{ sum: 0L, succ: 0L, fail: 0L, drop: 0L, }
  w.each(now, b => {
    s.sum = s.sum + b.sum
    s.succ = s.succ + b.succ
    s.fail = s.fail + b.fail
    s.drop = s.drop + b.drop
  })
  s
}

///|
test "the window holds size * bucket_ms of history and nothing older" {
  let w = Window::new(size=4, bucket_ms=100L)
  w.add(Succ, 0L)
  w.add(Fail, 100L)
  w.add(Succ, 200L)
  w.add(Succ, 300L)
  let live = sums(w, 300L)
  assert_eq(live.sum, 4L)
  assert_eq(live.succ, 3L)
  assert_eq(live.fail, 1L)
  // a write four buckets on wipes the whole window before recording
  w.add(Drop, 700L)
  let rolled = sums(w, 700L)
  assert_eq(rolled.sum, 1L)
  assert_eq(rolled.succ, 0L)
  assert_eq(rolled.fail, 0L)
  assert_eq(rolled.drop, 1L)
}

///|
test "an idle window ages out on its own, and reading never clears it" {
  let w = Window::new(size=4, bucket_ms=100L)
  w.add(Succ, 0L)
  assert_eq(sums(w, 300L).sum, 1L)
  assert_eq(sums(w, 400L).sum, 0L)
  assert_eq(sums(w, 300L).sum, 1L)
}

///|
test "the write cursor snaps to bucket boundaries instead of drifting" {
  let w = Window::new(size=4, bucket_ms=100L)
  w.add(Succ, 0L)
  assert_eq(w.offset, 0)
  assert_eq(w.bucket_start, 0L)
  w.add(Fail, 150L)
  assert_eq(w.offset, 1)
  assert_eq(w.bucket_start, 100L)
  // 199 is still inside that same 100ms slice
  w.add(Fail, 199L)
  assert_eq(w.offset, 1)
  w.add(Succ, 201L)
  assert_eq(w.offset, 2)
  assert_eq(w.bucket_start, 200L)
  let s = sums(w, 201L)
  assert_eq(s.succ, 2L)
  assert_eq(s.fail, 2L)
}

///|
test "a nonsense size is clamped and a backwards clock is no elapsed time" {
  let w = Window::new(size=0, bucket_ms=0L, now=1000L)
  assert_eq(w.size, 1)
  assert_eq(w.bucket_ms, 1L)
  w.add(Succ, 900L)
  assert_eq(w.bucket_start, 1000L)
  assert_eq(sums(w, 900L).succ, 1L)
}
