///|
test "endpoint address and default weight" {
  let e = Endpoint::new("127.0.0.1", 8080)
  assert_eq(e.address(), "127.0.0.1:8080")
  assert_eq(e.weight, 1)
  let w = Endpoint::new("10.0.0.5", 9000, weight=5)
  assert_eq(w.weight, 5)
  assert_eq(w.address(), "10.0.0.5:9000")
}

///|
test "registry registers, resolves, and lists services" {
  let reg = InMemoryRegistry::new()
  assert_eq(reg.revision(), 0L)
  assert_eq(reg.resolve("greeter").length(), 0)
  let k1 = reg.register("greeter", Endpoint::new("10.0.0.1", 9001))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  assert_eq(reg.resolve("greeter").length(), 2)
  assert_eq(reg.revision(), 2L)
  // distinct keys for distinct instances
  assert_eq(k1, "greeter/1")
  let services = reg.services()
  assert_eq(services.length(), 1)
  assert_eq(services[0], "greeter")
}

///|
test "registry deregister removes an instance and bumps the revision" {
  let reg = InMemoryRegistry::new()
  let k1 = reg.register("svc", Endpoint::new("a", 1))
  let _ = reg.register("svc", Endpoint::new("b", 2))
  assert_eq(reg.resolve("svc").length(), 2)
  let rev_before = reg.revision()
  assert_eq(reg.deregister("svc", k1), true)
  assert_eq(reg.resolve("svc").length(), 1)
  assert_eq(reg.revision(), rev_before + 1L)
  // the survivor is the second instance
  assert_eq(reg.resolve("svc")[0].address(), "b:2")
}

///|
test "registry deregister of an unknown key or service is a no-op" {
  let reg = InMemoryRegistry::new()
  assert_eq(reg.deregister("nope", "nope/1"), false)
  let _ = reg.register("svc", Endpoint::new("a", 1))
  let rev = reg.revision()
  assert_eq(reg.deregister("svc", "svc/999"), false)
  // a failed deregister must not bump the revision
  assert_eq(reg.revision(), rev)
}

///|
test "round-robin balancer cycles through the instances" {
  let lb = RoundRobin::new()
  let eps = [
    Endpoint::new("a", 1),
    Endpoint::new("b", 2),
    Endpoint::new("c", 3),
  ]
  assert_eq(lb.pick(eps).unwrap().address(), "a:1")
  assert_eq(lb.pick(eps).unwrap().address(), "b:2")
  assert_eq(lb.pick(eps).unwrap().address(), "c:3")
  assert_eq(lb.pick(eps).unwrap().address(), "a:1")
}

///|
test "round-robin and pick_first on an empty set return None" {
  let lb = RoundRobin::new()
  assert_eq(lb.pick([]) is None, true)
  assert_eq(pick_first([]) is None, true)
  assert_eq(pick_first([Endpoint::new("a", 1)]).unwrap().address(), "a:1")
}

///|
test "resolve_one drives a Discovery through the balancer" {
  let reg = InMemoryRegistry::new()
  let _ = reg.register("greeter", Endpoint::new("10.0.0.1", 9001))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  let lb = RoundRobin::new()
  assert_eq(resolve_one(reg, "greeter", lb).unwrap().address(), "10.0.0.1:9001")
  assert_eq(resolve_one(reg, "greeter", lb).unwrap().address(), "10.0.0.2:9002")
  // an unknown service yields no endpoint
  assert_eq(resolve_one(reg, "absent", lb) is None, true)
}
