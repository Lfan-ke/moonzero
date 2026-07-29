///|
/// A real file round-trip: a publisher registers an instance and persists the
/// registry to a shared file; a separately loaded reader `reload`s from that file
/// and sees exactly that instance, surfaced as a single `Put`. The bytes travel
/// through a real `@fs.write_file`/`@fs.read_file`, so a green result means the
/// snapshot document survived a genuine disk round-trip and the diff is correct.
async test "file registry round-trips a real file: reload picks up a persisted instance" {
  @async.with_task_group(_g => {
    let dir = @fs.tmpdir(prefix="mz-reg-rt")
    let path = dir + "/registry.json"
    let writer = @moonzero.PersistentRegistry::new()
    persist_registry(path, writer)
    let reader = FileRegistry::load(path)
    assert_eq(reader.resolve("greet.Greeter").length(), 0)
    let _ = writer.register(
      "greet.Greeter",
      @moonzero.Endpoint::new("10.0.0.7", 9001),
    )
    persist_registry(path, writer)
    let events = reader.reload()
    assert_eq(events.length(), 1)
    match events[0] {
      Put(endpoint~, ..) => assert_eq(endpoint.address(), "10.0.0.7:9001")
      Delete(..) => fail("expected a Put event")
    }
    let eps = reader.resolve("greet.Greeter")
    assert_eq(eps.length(), 1)
    assert_eq(eps[0], @moonzero.Endpoint::new("10.0.0.7", 9001))
  })
}

///|
/// When a publisher deregisters an instance and rewrites the file, the reader's next
/// `reload` reports a `Delete` for the key that left and drops it from `resolve`.
async test "file registry reload emits a Delete when an instance leaves" {
  @async.with_task_group(_g => {
    let dir = @fs.tmpdir(prefix="mz-reg-del")
    let path = dir + "/registry.json"
    let writer = @moonzero.PersistentRegistry::new()
    let key = writer.register(
      "greet.Greeter",
      @moonzero.Endpoint::new("10.0.0.7", 9001),
    )
    persist_registry(path, writer)
    let reader = FileRegistry::load(path)
    assert_eq(reader.resolve("greet.Greeter").length(), 1)
    let removed = writer.deregister("greet.Greeter", key)
    assert_eq(removed, true)
    persist_registry(path, writer)
    let events = reader.reload()
    assert_eq(events.length(), 1)
    match events[0] {
      Delete(key~, ..) => assert_eq(key, "greet.Greeter/1")
      Put(..) => fail("expected a Delete event")
    }
    assert_eq(reader.resolve("greet.Greeter").length(), 0)
  })
}

///|
/// A load-balanced zRPC channel resolves through a file-backed registry: after the
/// reader reloads the file the publisher wrote, `resolver()` hands the balancer the
/// on-disk instance set, and pick-first selects it. Ties the real registry I/O to
/// the discovery path a client actually calls through.
async test "file registry drives a balancer after a real reload" {
  @async.with_task_group(_g => {
    let dir = @fs.tmpdir(prefix="mz-reg-lb")
    let path = dir + "/registry.json"
    let writer = @moonzero.PersistentRegistry::new()
    let _ = writer.register(
      "greet.Greeter",
      @moonzero.Endpoint::new("10.0.0.5", 8443),
    )
    persist_registry(path, writer)
    let reader = FileRegistry::load(path)
    let _ = reader.reload()
    let resolve = reader.resolver()
    match @moonzero.pick_first(resolve("greet.Greeter")) {
      Some(ep) => assert_eq(ep.address(), "10.0.0.5:8443")
      None => fail("expected the on-disk instance to resolve")
    }
  })
}

///|
/// The live watcher: a reader watches the directory while a publisher registers an
/// instance and rewrites the file. The watch cycle fires on the real filesystem
/// change, reloads, and returns the `Put` for the new instance. This is the
/// watch-fires-on-change milestone — a genuine OS file-watch round-trip.
async test "file registry watcher fires on a real file change" {
  @async.with_task_group(g => {
    let dir = @fs.tmpdir(prefix="mz-watch")
    let path = dir + "/registry.json"
    let writer = @moonzero.PersistentRegistry::new()
    persist_registry(path, writer)
    let reader = FileRegistry::load(path)
    let watcher = @fs.Watcher(dir)
    let holder : Ref[Array[@moonzero.RegistryEvent]] = Ref([])
    let task = g.spawn(() => holder.val = reader.watch_once(watcher))
    @async.sleep(200)
    let _ = writer.register(
      "greet.Greeter",
      @moonzero.Endpoint::new("10.0.0.9", 9100),
    )
    persist_registry(path, writer)
    task.wait()
    watcher.close()
    let events = holder.val
    assert_eq(events.length() >= 1, true)
    let mut saw = false
    for event in events {
      match event {
        Put(endpoint~, ..) => if endpoint.port == 9100 { saw = true }
        Delete(..) => ()
      }
    }
    assert_eq(saw, true)
  })
}
