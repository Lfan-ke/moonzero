///|
/// Both registries expose a `Resolve` closure, so a `LoadBalancedChannel` drives
/// either backing store. Here the in-memory registry backs the channel end to end —
/// resolve, balance, dial, call — the same path the persisted registry drives below.
test "load-balanced channel works over the in-memory registry too" {
  let reg = InMemoryRegistry::new()
  let cluster = RpcCluster::new()
  let ep = Endpoint::new("10.0.0.7", 8100)
  let srv = RpcServer::new(RpcServerConf::new())
  srv.group("hello.Greeter").register("Who", _req => @utf8.encode("mem"))
  cluster.add(ep, srv)
  let _ = reg.register("hello.Greeter", ep)
  let ch = LoadBalancedChannel::new(reg.resolver(), cluster, "hello.Greeter")
  match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => assert_eq(v, @utf8.encode("mem"))
    Err(s) => fail("call failed: " + s.name())
  }
}

///|
test "persistent registry registers, resolves, and bumps the revision" {
  let reg = PersistentRegistry::new()
  assert_eq(reg.revision(), 0L)
  let k1 = reg.register("greeter", Endpoint::new("10.0.0.1", 9001))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  assert_eq(k1, "greeter/1")
  assert_eq(reg.resolve("greeter").length(), 2)
  assert_eq(reg.revision(), 2L)
  assert_eq(reg.services().length(), 1)
}

///|
test "persistent registry deregister removes an instance and emits a Delete" {
  let reg = PersistentRegistry::new()
  let k1 = reg.register("svc", Endpoint::new("a", 1))
  let _ = reg.register("svc", Endpoint::new("b", 2))
  assert_eq(reg.deregister("svc", k1), true)
  assert_eq(reg.resolve("svc").length(), 1)
  assert_eq(reg.resolve("svc")[0].address(), "b:2")
  // a failed deregister neither removes nor bumps the revision
  let rev = reg.revision()
  assert_eq(reg.deregister("svc", "svc/999"), false)
  assert_eq(reg.revision(), rev)
}

///|
/// A live watcher sees every mutation after it subscribes, in revision order, as
/// etcd-shaped Put/Delete events.
test "persistent registry watch delivers Put and Delete events in order" {
  let reg = PersistentRegistry::new()
  let seen : Array[RegistryEvent] = []
  reg.watch(e => seen.push(e))
  let k = reg.register("svc", Endpoint::new("a", 1))
  let _ = reg.register("svc", Endpoint::new("b", 2))
  let _ = reg.deregister("svc", k)
  assert_eq(seen.length(), 3)
  assert_eq(
    seen[0],
    Put(key="svc/1", endpoint=Endpoint::new("a", 1), revision=1L),
  )
  assert_eq(
    seen[1],
    Put(key="svc/2", endpoint=Endpoint::new("b", 2), revision=2L),
  )
  assert_eq(seen[2], Delete(key="svc/1", revision=3L))
}

///|
/// A watcher that subscribes late replays missed changes with `events_since`, then
/// switches to live callbacks — etcd's start-revision catch-up.
test "persistent registry events_since replays only newer changes" {
  let reg = PersistentRegistry::new()
  let _ = reg.register("svc", Endpoint::new("a", 1))
  let mark = reg.revision()
  let _ = reg.register("svc", Endpoint::new("b", 2))
  let _ = reg.register("svc", Endpoint::new("c", 3))
  let missed = reg.events_since(mark)
  assert_eq(missed.length(), 2)
  assert_eq(missed[0].revision(), 2L)
  assert_eq(missed[1].revision(), 3L)
  // nothing is newer than the current revision
  assert_eq(reg.events_since(reg.revision()).length(), 0)
}

///|
/// The registry serializes to an etcd v3 `RangeResponse`-shaped snapshot and
/// restores to an identical registry: same instances, same revision, and the id
/// counter continues where it left off so the next key does not collide.
test "persistent registry snapshot round-trips through restore" {
  let reg = PersistentRegistry::new()
  let _ = reg.register("greeter", Endpoint::new("10.0.0.1", 9001, weight=3))
  let _ = reg.register("greeter", Endpoint::new("10.0.0.2", 9002))
  let _ = reg.register("orders", Endpoint::new("10.0.0.9", 7000))
  let snap = reg.snapshot()
  let restored = PersistentRegistry::restore(snap)
  assert_eq(restored.revision(), reg.revision())
  assert_eq(restored.resolve("greeter").length(), 2)
  assert_eq(restored.resolve("orders").length(), 1)
  // the weight survived the round-trip
  let g = restored.resolve("greeter")
  let mut found = false
  for e in g {
    if e.address() == "10.0.0.1:9001" {
      assert_eq(e.weight, 3)
      found = true
    }
  }
  assert_eq(found, true)
  // the id counter resumes: the next key is /4, not a collision with /1
  let k = restored.register("greeter", Endpoint::new("10.0.0.3", 9003))
  assert_eq(k, "greeter/4")
}

///|
test "balancer round-robin and pick-first over a resolved set" {
  let eps = [Endpoint::new("a", 1), Endpoint::new("b", 2)]
  let rr = Balancer::round_robin()
  assert_eq(rr.pick(eps).unwrap().address(), "a:1")
  assert_eq(rr.pick(eps).unwrap().address(), "b:2")
  assert_eq(rr.pick(eps).unwrap().address(), "a:1")
  let pf : Balancer = PickFirst
  assert_eq(pf.pick(eps).unwrap().address(), "a:1")
  assert_eq(pf.pick(eps).unwrap().address(), "a:1")
  assert_eq(rr.pick([]) is None, true)
  assert_eq(pf.pick([]) is None, true)
}

///|
/// The load-balanced client end to end: two greeter instances register in a
/// persisted registry, both bound in the cluster, and a round-robin channel
/// resolves and dials a live instance per call — each answering with its own
/// address so the alternation is observable. This is the registry-resolve→call
/// milestone, driven all the way through the real h2c transport.
test "load-balanced channel resolves and round-robins across instances" {
  let reg = PersistentRegistry::new()
  let cluster = RpcCluster::new()
  let a = Endpoint::new("10.0.0.1", 9001)
  let b = Endpoint::new("10.0.0.2", 9002)
  for pair in [(a, "instance-a"), (b, "instance-b")] {
    let (ep, tag) = pair
    let srv = RpcServer::new(RpcServerConf::new())
    let marker = @utf8.encode(tag)
    srv.group("hello.Greeter").register("Who", _req => marker)
    cluster.add(ep, srv)
    let _ = reg.register("hello.Greeter", ep)
  }
  let ch = LoadBalancedChannel::new(reg.resolver(), cluster, "hello.Greeter")
  let r1 = match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => v
    Err(s) => fail("call 1 failed: " + s.name())
  }
  let r2 = match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => v
    Err(s) => fail("call 2 failed: " + s.name())
  }
  // round-robin hits the two instances in turn
  assert_eq(r1, @utf8.encode("instance-a"))
  assert_eq(r2, @utf8.encode("instance-b"))
  // a third call wraps back to the first
  match ch.call("/hello.Greeter/Who", b"") {
    Ok(v) => assert_eq(v, @utf8.encode("instance-a"))
    Err(s) => fail("call 3 failed: " + s.name())
  }
}

///|
/// A load-balanced call to a service with no registered instance fails
/// `Unavailable`, the status a real client reports when no subchannel is ready.
test "load-balanced channel with no instances is Unavailable" {
  let reg = PersistentRegistry::new()
  let cluster = RpcCluster::new()
  let ch = LoadBalancedChannel::new(reg.resolver(), cluster, "absent.Service")
  match ch.call("/absent.Service/Method", b"") {
    Ok(_) => fail("no instance should not return OK")
    Err(s) => assert_eq(s == @moonrpc.Status::Unavailable, true)
  }
}

///|
/// The load-balanced client also carries server-streaming calls: it resolves an
/// instance, then streams every framed reply back.
test "load-balanced channel carries a server-streaming call" {
  let reg = PersistentRegistry::new()
  let cluster = RpcCluster::new()
  let ep = Endpoint::new("10.0.0.1", 9001)
  let srv = RpcServer::new(RpcServerConf::new())
  srv
  .group("feed.Feed")
  .register_server_streaming("Tail", _req => [b"x1", b"x2"])
  cluster.add(ep, srv)
  let _ = reg.register("feed.Feed", ep)
  let ch = LoadBalancedChannel::new(
    reg.resolver(),
    cluster,
    "feed.Feed",
    balancer=PickFirst,
  )
  match ch.call_server_streaming("/feed.Feed/Tail", b"") {
    Ok(msgs) => {
      assert_eq(msgs.length(), 2)
      assert_eq(msgs[0], b"x1")
      assert_eq(msgs[1], b"x2")
    }
    Err(s) => fail("stream failed: " + s.name())
  }
}
