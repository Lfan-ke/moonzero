///|
/// Walk the service-discovery layer: the in-memory and persisted registries, the
/// round-robin and pick-first balancers, a watch/snapshot/restore round-trip on
/// the persisted registry, and a load-balanced zRPC channel that resolves and
/// balances across two live instances on every call.
///
///     moon run examples/08-discovery
#coverage.skip
fn main {
  try {
    let ep1 = @moonzero.Endpoint::new("10.0.0.1", 9090)
    let ep2 = @moonzero.Endpoint::new("10.0.0.2", 9090)
    let ep3 = @moonzero.Endpoint::new("10.0.0.3", 9090, weight=5)

    // In-memory registry: register, resolve, revision, deregister.
    let reg = @moonzero.InMemoryRegistry::new()
    let k1 = reg.register("greeter", ep1)
    let _ = reg.register("greeter", ep2)
    println(
      "in-memory: " +
      addrs(reg.resolve("greeter")) +
      " services=" +
      join(reg.services()) +
      " rev=" +
      reg.revision().to_string(),
    )
    let _ = reg.deregister("greeter", k1)
    println(
      "  after deregister one: " +
      addrs(reg.resolve("greeter")) +
      " rev=" +
      reg.revision().to_string(),
    )

    // Balancers over a fixed resolved set.
    let set = [ep1, ep2, ep3]
    let rr = @moonzero.RoundRobin::new()
    println("round-robin cycle: " + pick3(rr, set))
    println("pick_first pins head: " + one(@moonzero.pick_first(set)))
    println(
      "resolve_one(round-robin): " +
      one(@moonzero.resolve_one(reg, "greeter", @moonzero.RoundRobin::new())),
    )
    let balancer = @moonzero.Balancer::round_robin()
    println("Balancer::pick: " + one(balancer.pick(set)))

    // Persisted registry: a live watcher records every mutation in revision order.
    let events : Array[@moonzero.RegistryEvent] = []
    let preg = @moonzero.PersistentRegistry::new()
    preg.watch(e => events.push(e))
    let pk1 = preg.register("greeter", ep1)
    let _ = preg.register("greeter", ep2)
    let _ = preg.deregister("greeter", pk1)
    println("persisted watch events: " + join(events.map(event_str)))
    println(
      "  events since rev 1: " + join(preg.events_since(1L).map(event_str)),
    )
    println("  keyed entries: " + join(preg.keyed_entries().map(entry_str)))

    // snapshot/restore round-trips the whole keyspace, revisions intact, so a
    // reloaded registry mints the next key exactly where the persisted one left off.
    let snap = preg.snapshot()
    let restored = @moonzero.PersistentRegistry::restore(snap)
    println(
      "restore preserves revision: " +
      (restored.revision() == preg.revision()).to_string(),
    )
    let next_key = restored.register("greeter", ep3)
    println("  restored registry continues key sequence: " + next_key)

    // Load-balanced channel: resolve -> balance -> dial -> call, per call.
    let a = greeter("from A")
    let b = greeter("from B")
    let cluster = @moonzero.RpcCluster::new()
    cluster.add(ep1, a)
    cluster.add(ep2, b)
    let live = @moonzero.InMemoryRegistry::new()
    let _ = live.register("greeter", ep1)
    let _ = live.register("greeter", ep2)
    let lb = @moonzero.LoadBalancedChannel::new(
      live.resolver(),
      cluster,
      "greeter",
    )
    let r1 = call_lb(lb)
    let r2 = call_lb(lb)
    println("load-balanced two calls: [" + r1 + ", " + r2 + "]")
    println(
      "  spread across both instances: " +
      (r1 != r2 && r1 != "err" && r2 != "err").to_string(),
    )
    println(
      "  server-streaming via LB: " +
      lb_stream(
        lb.call_server_streaming("/hello.Greeter/Tail", @utf8.encode("x")),
      ),
    )

    // A service with no registered instances resolves to Unavailable.
    let empty = @moonzero.LoadBalancedChannel::new(
      live.resolver(),
      cluster,
      "absent",
    )
    println("  unknown service -> " + call_lb(empty))
  } catch {
    _ => println("unexpected transport error")
  }
}

///|
/// A one-method greeter whose reply carries `tag`, so a load-balanced caller can
/// tell which instance answered.
fn greeter(tag : String) -> @moonzero.RpcServer {
  let rpc = @moonzero.RpcServer::new(
    @moonzero.RpcServerConf::new(name="greeter"),
  )
  let g = rpc.group("hello.Greeter")
  g.register("SayHello", _req => @utf8.encode(tag))
  g.register_server_streaming("Tail", _req => {
    [@utf8.encode(tag), @utf8.encode(tag)]
  })
  rpc
}

///|
fn call_lb(lb : @moonzero.LoadBalancedChannel) -> String raise {
  match lb.call("/hello.Greeter/SayHello", @utf8.encode("q")) {
    Ok(b) => @utf8.decode_lossy(b[:])
    Err(_) => "err"
  }
}

///|
fn lb_stream(r : Result[Array[Bytes], @moonrpc.Status]) -> String {
  match r {
    Ok(msgs) => join(msgs.map(b => @utf8.decode_lossy(b[:])))
    Err(s) => "err(" + s.name() + ")"
  }
}

///|
fn pick3(rr : @moonzero.RoundRobin, set : Array[@moonzero.Endpoint]) -> String {
  join([
    one(rr.pick(set)),
    one(rr.pick(set)),
    one(rr.pick(set)),
    one(rr.pick(set)),
  ])
}

///|
fn one(ep : @moonzero.Endpoint?) -> String {
  match ep {
    Some(e) => e.address()
    None => "none"
  }
}

///|
fn addrs(eps : Array[@moonzero.Endpoint]) -> String {
  let a = eps.map(e => e.address())
  a.sort()
  join(a)
}

///|
fn event_str(e : @moonzero.RegistryEvent) -> String {
  match e {
    Put(key~, endpoint~, revision~) =>
      "Put(" + key + "=" + endpoint.address() + "@" + revision.to_string() + ")"
    Delete(key~, revision~) =>
      "Delete(" + key + "@" + revision.to_string() + ")"
  }
}

///|
fn entry_str(e : (String, @moonzero.Endpoint, Int64)) -> String {
  let (key, ep, rev) = e
  key + "=" + ep.address() + "@" + rev.to_string()
}

///|
fn join(items : Array[String]) -> String {
  let sb = StringBuilder::new()
  sb.write_char('[')
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(items[i])
  }
  sb.write_char(']')
  sb.to_string()
}
