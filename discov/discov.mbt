// Real registry I/O for moonzero's service discovery. go-zero's `discov` publishes
// service instances into etcd and watches for changes over the network; this driver
// does the same round-trip over a real medium a CI job always has — the local
// filesystem — through `moonbitlang/async`'s fs. A publisher persists the registry
// snapshot to a file; a reader loads it, exposes a `Resolve`, and either reloads on
// demand or watches the directory and reloads on every change, emitting the same
// `RegistryEvent` diff a watcher of an etcd keyspace would. All protocol shapes
// (the snapshot document, the event diff, the balancers) live in the backend-
// agnostic root package; this file only moves bytes to and from disk.

///|
/// Persist a registry's whole keyspace to `path` as its etcd v3 `RangeResponse`-
/// shaped snapshot document (← go-zero's `discov.Publisher` writing instance keys
/// into etcd). The file is truncated and rewritten, so it always holds the current
/// state and its revisions; a reader `load`s or `reload`s from exactly these bytes.
pub async fn persist_registry(
  path : String,
  reg : @moonzero.PersistentRegistry,
) -> Unit {
  @fs.write_file(path, reg.snapshot(), create_mode=CreateOrTruncate)
}

///|
/// A file-backed view of a service registry (← go-zero's `discov.Subscriber`): it
/// holds the last-loaded `PersistentRegistry` and the file it came from. `resolve`
/// answers from the in-memory copy; `reload` re-reads the file and returns the
/// `Put`/`Delete` events that the change produced; `watch_once`/`watch` block on a
/// real filesystem watcher and reload when the file changes. The reader and the
/// publisher share only the file, exactly as an etcd subscriber and publisher share
/// only the etcd keyspace.
pub struct FileRegistry {
  path : String
  mut reg : @moonzero.PersistentRegistry
}

///|
/// Read the registry snapshot at `path` into a fresh `FileRegistry`. A missing file
/// is treated as an empty registry, so a reader can start before the publisher has
/// written anything and pick the state up on the first `reload`/`watch`.
pub async fn FileRegistry::load(path : String) -> FileRegistry {
  { path, reg: read_snapshot(path), }
}

///|
/// The current file path this registry loads from.
pub fn FileRegistry::path(self : FileRegistry) -> String {
  self.path
}

///|
/// The store revision of the last-loaded snapshot.
pub fn FileRegistry::revision(self : FileRegistry) -> Int64 {
  self.reg.revision()
}

///|
/// The endpoints registered for `service` in the last-loaded snapshot.
pub fn FileRegistry::resolve(
  self : FileRegistry,
  service : String,
) -> Array[@moonzero.Endpoint] {
  self.reg.resolve(service)
}

///|
/// This file registry as a `Resolve` interface value, so a balancer and the
/// load-balanced channel drive it exactly as they drive the in-memory registry.
/// The closure reads whatever snapshot was last loaded, so a `reload`/`watch` in
/// between calls is reflected on the next resolve.
pub fn FileRegistry::resolver(self : FileRegistry) -> @moonzero.Resolve {
  service => self.resolve(service)
}

///|
/// Re-read the file and adopt it as the current state, returning the `RegistryEvent`
/// diff from the previously loaded state: a `Put` for every instance that is new or
/// whose endpoint changed, a `Delete` for every instance that went away. The events
/// carry the mod-revision the reloaded snapshot recorded, so a client can stay in
/// revision order across reloads.
pub async fn FileRegistry::reload(
  self : FileRegistry,
) -> Array[@moonzero.RegistryEvent] {
  let fresh = read_snapshot(self.path)
  let events = diff_registries(self.reg, fresh)
  self.reg = fresh
  events
}

///|
/// Block on `watcher` until the watched directory changes, then `reload` and return
/// the diff — one watch cycle. The caller owns the `@fs.Watcher` (built over the
/// directory holding the registry file) and its lifetime, so a single cycle is easy
/// to drive to completion and join; `watch` loops this for a long-running reader.
pub async fn FileRegistry::watch_once(
  self : FileRegistry,
  watcher : @fs.Watcher,
) -> Array[@moonzero.RegistryEvent] {
  let _ = watcher.wait()
  self.reload()
}

///|
/// Watch `dir` (the directory holding the registry file) and invoke `on_event` for
/// every `RegistryEvent` produced by every change, indefinitely — the long-running
/// subscribe loop (← go-zero's `discov.Subscriber` watch goroutine). Runs until the
/// surrounding task group is torn down; drive it with `TaskGroup::spawn`.
pub async fn FileRegistry::watch(
  self : FileRegistry,
  dir : String,
  on_event : (@moonzero.RegistryEvent) -> Unit,
) -> Unit {
  let watcher = @fs.Watcher(dir)
  for ;; {
    for event in self.watch_once(watcher) {
      on_event(event)
    }
  }
}

///|
/// Read and parse the snapshot at `path`, or an empty registry if the file is
/// absent.
async fn read_snapshot(path : String) -> @moonzero.PersistentRegistry {
  if @fs.exists(path) {
    let data = @fs.read_file(path)
    @moonzero.PersistentRegistry::restore(data.text())
  } else {
    @moonzero.PersistentRegistry::new()
  }
}

///|
/// Compute the `RegistryEvent` diff turning `old` into `new`, keyed by instance
/// key: a `Put` for each key present in `new` but absent or changed in `old`
/// (carrying `new`'s mod-revision), and a `Delete` for each key present in `old` but
/// gone from `new` (carrying `new`'s store revision).
fn diff_registries(
  old : @moonzero.PersistentRegistry,
  new : @moonzero.PersistentRegistry,
) -> Array[@moonzero.RegistryEvent] {
  let old_map : Map[String, @moonzero.Endpoint] = Map([])
  for entry in old.keyed_entries() {
    let (key, ep, _) = entry
    old_map[key] = ep
  }
  let events : Array[@moonzero.RegistryEvent] = []
  let present : Map[String, Bool] = Map([])
  for entry in new.keyed_entries() {
    let (key, ep, rev) = entry
    present[key] = true
    let changed = match old_map.get(key) {
      Some(prev) => !(prev == ep)
      None => true
    }
    if changed {
      events.push(Put(key~, endpoint=ep, revision=rev))
    }
  }
  for entry in old.keyed_entries() {
    let (key, _, _) = entry
    if !present.contains(key) {
      events.push(Delete(key~, revision=new.revision()))
    }
  }
  events
}
