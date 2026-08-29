///|
/// The native `discov` driver over a real file: a publisher persists the registry
/// snapshot to disk, a `FileRegistry` loads it and answers resolves, and after the
/// publisher mutates and re-persists, the reader's `reload` returns the Put/Delete
/// diff since its last load — the same publish/subscribe round-trip go-zero's
/// `discov` runs over etcd, here over the filesystem.
///
///     moon run --target native examples/14-discov-file
#coverage.skip
async fn main {
  let path = ".moonzero-discov-registry.json"

  // Publisher: register two instances and persist the snapshot to a real file.
  let reg = @moonzero.PersistentRegistry::new()
  let _ = reg.register("greeter", @moonzero.Endpoint::new("10.0.0.1", 9090))
  let k2 = reg.register("greeter", @moonzero.Endpoint::new("10.0.0.2", 9090))
  @discov.persist_registry(path, reg)
  println("published snapshot at revision " + reg.revision().to_string())

  // Subscriber: load the file back and answer from the in-memory copy.
  let reader = @discov.FileRegistry::load(path)
  println(
    "reader path=" +
    reader.path() +
    " revision=" +
    reader.revision().to_string(),
  )
  println("resolve greeter: " + addrs(reader.resolve("greeter")))
  println("via resolver interface: " + addrs(reader.resolver()("greeter")))

  // Publisher mutates — add a third instance, drop the second — and re-persists.
  let _ = reg.register("greeter", @moonzero.Endpoint::new("10.0.0.3", 9090))
  let _ = reg.deregister("greeter", k2)
  @discov.persist_registry(path, reg)

  // Subscriber reloads and gets the diff its state changed by.
  let events = reader.reload()
  println("reload diff: " + join(events.map(event_str)))
  println(
    "after reload: " +
    addrs(reader.resolve("greeter")) +
    " revision=" +
    reader.revision().to_string(),
  )
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
fn addrs(eps : Array[@moonzero.Endpoint]) -> String {
  let a = eps.map(e => e.address())
  a.sort()
  let sb = StringBuilder()
  sb.write_char('[')
  for i = 0; i < a.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(a[i])
  }
  sb.write_char(']')
  sb.to_string()
}

///|
fn join(items : Array[String]) -> String {
  let sb = StringBuilder()
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
