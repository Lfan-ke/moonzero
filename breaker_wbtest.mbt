///|
/// A roll the test can turn between calls: the breaker draws `face` every time
/// it decides.
priv struct Dice {
  mut face : Double
}

///|
priv suberror Boom

///|
fn bust() -> Int raise {
  raise Boom
}

///|
/// Take one call through the breaker and settle it as `o`.
fn settle(b : Breaker, o : Outcome) -> Unit raise {
  guard b.allow() is Some(p) else {
    fail("the breaker shed a call it should admit")
  }
  match o {
    Succ => p.accept()
    Fail => p.reject()
    Drop => fail("a settled call is not a drop")
  }
}

///|
test "the drop ratio follows the SRE formula as failures pile up" {
  let mc = ManualClock::new()
  // the ratio is always below 1, so a roll of 1.0 never sheds: what this test
  // sees is the formula alone, with the draw taken out of it
  let b = Breaker::new(mc.as_clock(), rand=() => 1.0)
  for _ in 0..<5 {
    settle(b, Fail)
  }
  // five failures are exactly the protection floor, so nothing sheds yet
  assert_eq(b.drop_ratio(), 0.0)
  settle(b, Fail)
  assert_eq(b.drop_ratio(), 1.0 / 7.0)
  settle(b, Fail)
  assert_eq(b.drop_ratio(), 2.0 / 8.0)
  // one success is worth k = 1.5 against the seven failures
  settle(b, Succ)
  assert_eq(b.drop_ratio(), (8.0 - 5.0 - 1.5) / 9.0)
}

///|
test "a run of all-failure buckets decays the weight on past successes" {
  let mc = ManualClock::new()
  let b = Breaker::new(mc.as_clock(), rand=() => 1.0)
  for _ in 0..<4 {
    settle(b, Succ)
  }
  mc.advance(250)
  for _ in 0..<20 {
    settle(b, Fail)
  }
  // one failing bucket out of forty: w = 1.5 - 0.4/40 = 1.49, so the four
  // successes are worth 5.96 against 24 calls
  assert_eq(b.drop_ratio(), 0.5216)
  mc.advance(250)
  for _ in 0..<20 {
    settle(b, Fail)
  }
  // a second failing bucket pulls w to 1.48 and the ratio up with it
  assert_eq(b.drop_ratio(), 0.735111111111111)
}

///|
test "a healthy stream is never shed, however the roll lands" {
  let mc = ManualClock::new()
  // 0.0 loses every draw the breaker takes, so a shed here would be the
  // formula's doing and not the dice's
  let b = Breaker::new(mc.as_clock(), rand=() => 0.0)
  for _ in 0..<200 {
    settle(b, Succ)
    mc.advance(50)
  }
  assert_eq(b.drop_ratio(), 0.0)
}

///|
test "a shed call counts as traffic, and a silent second forces one probe" {
  let mc = ManualClock::new()
  let dice = Dice::{ face: 1.0, }
  let b = Breaker::new(mc.as_clock(), rand=() => dice.face)
  for _ in 0..<7 {
    settle(b, Fail)
  }
  assert_eq(b.drop_ratio(), 0.25)
  // from here every draw loses, so the 0.25 throttle sheds
  dice.face = 0.0
  mc.advance(100)
  assert_eq(b.allow() is None, true)
  // the shed is itself in the window: 7 calls became 8
  assert_eq(b.drop_ratio(), 3.0 / 9.0)
  // nothing has got through for over a second, so one probe goes past the roll
  mc.advance(1001)
  guard b.allow() is Some(p) else { fail("the force-pass probe was shed") }
  p.accept()
  // and it spent the grace: the next call is back under the roll
  assert_eq(b.allow() is None, true)
}

///|
test "run settles the promise from the call and raises once shedding" {
  let mc = ManualClock::new()
  let b = Breaker::new(mc.as_clock(), rand=() => 0.0)
  assert_eq(b.run(() => 233), 233)
  for _ in 0..<6 {
    try {
      let _ = b.run(bust)
    } catch {
      Boom => ()
      e => fail("expected Boom, got " + e.to_string())
    }
  }
  // six failures against one k-weighted success put the ratio over zero
  try {
    let _ = b.run(() => 233)
  } catch {
    Unavailable => ()
    e => fail("expected Unavailable, got " + e.to_string())
  } noraise {
    _ => fail("a shed call should have raised")
  }
}
