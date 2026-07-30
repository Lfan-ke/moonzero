// The concurrent-request limiter (← go-zero's MaxConns).

///|
test "max conns: admits up to the limit, then rejects until a permit frees" {
  let m = MaxConns::new(2)
  assert_eq(m.try_acquire(), true)
  assert_eq(m.try_acquire(), true)
  assert_eq(m.in_flight(), 2)
  // At the limit, the next request is refused.
  assert_eq(m.try_acquire(), false)
  // Returning a permit admits one more.
  m.release()
  assert_eq(m.in_flight(), 1)
  assert_eq(m.try_acquire(), true)
  assert_eq(m.try_acquire(), false)
  // Releasing below zero is a no-op.
  m.release()
  m.release()
  m.release()
  assert_eq(m.in_flight(), 0)
}
