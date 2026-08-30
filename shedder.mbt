///|
/// Load shedding under CPU pressure (← go-zero's `load.AdaptiveShedder`, wired
/// from `RestConf.CpuThreshold`): admit while measured CPU sits at or below the
/// threshold, shed above it. Both numbers are per-mille, so go-zero's default
/// `900` means 90%.
///
/// go-zero reads `stat.CpuUsage()` and additionally sheds on in-flight count
/// against a moving pass/latency estimate. No MoonBit backend can read a CPU
/// meter, so the usage source is injected the way `Clock` is, and a shedder built
/// without one reports `0` and never sheds — the in-flight half is not modelled.
pub struct Shedder {
  threshold : Int64
  usage : () -> Int64
}

///|
/// A shedder that sheds once `usage` exceeds `threshold` per-mille.
pub fn Shedder::new(threshold : Int64, usage? : () -> Int64) -> Shedder {
  { threshold, usage: usage.unwrap_or(() => 0L), }
}

///|
/// Whether a request is admitted at the current usage.
pub fn Shedder::allow(self : Shedder) -> Bool {
  (self.usage)() <= self.threshold
}

///|
/// The CPU usage the shedder is reading, per mille.
pub fn Shedder::usage(self : Shedder) -> Int64 {
  (self.usage)()
}

///|
/// Shedding middleware (← go-zero's `SheddingHandler`): answer `503 Service
/// Unavailable` without running the app while the shedder is refusing, and pass
/// everything else through. Non-HTTP scopes are never shed.
pub fn shedding(s : Shedder) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if s.allow() {
            inner(scope, receive, send)
          } else {
            for event in service_unavailable_events() {
              send(event)
            }
          }
        _ => inner(scope, receive, send)
      }
    }
  }
}
