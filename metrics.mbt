///|
/// A monotonic counter (← go-zero's `metric.CounterVec`) partitioned by a label
/// string. Each `inc`/`add` accrues against one label (e.g. `"GET /ping 200"`),
/// so a single vector holds the per-method/route/status request tallies Prometheus
/// scrapes. Counters only ever go up.
pub struct CounterVec {
  counts : Map[String, Int64]
}

///|
/// A fresh counter vector with no labels seen yet.
pub fn CounterVec::new() -> CounterVec {
  { counts: Map([]) }
}

///|
/// Add `delta` to `label`'s count (creating the series on first sight).
pub fn CounterVec::add(
  self : CounterVec,
  label : String,
  delta : Int64,
) -> Unit {
  self.counts[label] = self.value(label) + delta
}

///|
/// Increment `label`'s count by one.
pub fn CounterVec::inc(self : CounterVec, label : String) -> Unit {
  self.add(label, 1L)
}

///|
/// The current count for `label`, `0` if never touched.
pub fn CounterVec::value(self : CounterVec, label : String) -> Int64 {
  self.counts.get(label).unwrap_or(0L)
}

///|
/// The sum of every label's count — the total number of observations.
pub fn CounterVec::total(self : CounterVec) -> Int64 {
  let mut sum = 0L
  for _, v in self.counts {
    sum = sum + v
  }
  sum
}

///|
/// The set of labels that have been observed.
pub fn CounterVec::labels(self : CounterVec) -> Array[String] {
  self.counts.keys().collect()
}

///|
/// A cumulative histogram (← go-zero's `metric.HistogramVec`, Prometheus
/// semantics): a sorted list of `le` (less-than-or-equal) upper bounds and, for
/// each, the count of observations that fell at or below it, plus the running
/// `sum` and total `count`. An observation above every bound still lands in the
/// implicit `+Inf` bucket that `count` represents.
pub struct Histogram {
  bounds : Array[Double]
  bucket : Array[Int64]
  mut sum : Double
  mut count : Int64
}

///|
/// The default latency buckets go-zero ships (milliseconds): a request spends
/// most of its time under a second, so the bounds cluster there.
pub let default_latency_buckets : Array[Double] = [
  1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000,
]

///|
/// A histogram over `bounds` (defaulting to `default_latency_buckets`). The
/// bounds are taken as given; supply them in ascending order, as Prometheus
/// requires.
pub fn Histogram::new(
  bounds? : Array[Double] = default_latency_buckets,
) -> Histogram {
  { bounds, bucket: Array::make(bounds.length(), 0L), sum: 0.0, count: 0 }
}

///|
/// Record one observation: it lands in every bucket whose `le` bound it does not
/// exceed (cumulative), and updates the sum and count.
pub fn Histogram::observe(self : Histogram, value : Double) -> Unit {
  for i = 0; i < self.bounds.length(); i = i + 1 {
    if value <= self.bounds[i] {
      self.bucket[i] = self.bucket[i] + 1L
    }
  }
  self.sum = self.sum + value
  self.count = self.count + 1L
}

///|
/// The total number of observations (the `+Inf` bucket count).
pub fn Histogram::total(self : Histogram) -> Int64 {
  self.count
}

///|
/// The sum of all observed values (Prometheus `_sum`).
pub fn Histogram::sum_value(self : Histogram) -> Double {
  self.sum
}

///|
/// The cumulative count in the bucket bounded by `bounds[i]` — how many
/// observations were `<=` that bound.
pub fn Histogram::bucket_count(self : Histogram, i : Int) -> Int64 {
  self.bucket[i]
}

///|
/// The upper bounds this histogram partitions on.
pub fn Histogram::bounds(self : Histogram) -> Array[Double] {
  self.bounds
}

///|
/// The mean of the observations, or `0` when none have been recorded.
pub fn Histogram::mean(self : Histogram) -> Double {
  if self.count == 0L {
    0.0
  } else {
    self.sum / self.count.to_double()
  }
}

///|
/// The request metrics an HTTP service exposes (← go-zero's server metrics): a
/// request counter partitioned by method/route/status and a latency histogram.
/// Held by the caller so it can be read out for a `/metrics` scrape after serving.
pub struct ServerMetrics {
  requests : CounterVec
  latency : Histogram
}

///|
/// Fresh server metrics: an empty counter and a default-bucket latency histogram.
pub fn ServerMetrics::new() -> ServerMetrics {
  { requests: CounterVec::new(), latency: Histogram::new() }
}

///|
/// The request counter, labelled `"<METHOD> <path> <status>"`.
pub fn ServerMetrics::requests(self : ServerMetrics) -> CounterVec {
  self.requests
}

///|
/// The request-latency histogram, in milliseconds.
pub fn ServerMetrics::latency(self : ServerMetrics) -> Histogram {
  self.latency
}

///|
/// Metrics middleware (← go-zero's `prometheus` interceptor): time each HTTP
/// request on the shared clock and, when the response starts, count it under
/// `"<METHOD> <path> <status>"` and record its latency in milliseconds. The
/// record is taken once per request even if a downstream (under a recovery race)
/// emits a second start. Non-HTTP scopes pass through unmeasured.
pub fn metrics(m : ServerMetrics, clock : Clock) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(hs) => {
          let start = clock.now()
          let verb = hs.http_method
          let path = hs.path
          let recorded : Ref[Bool] = { val: false }
          let observed : @moonasgi.Send = event => {
            match event {
              HttpResponseStart(status~, headers~) => {
                if !recorded.val {
                  recorded.val = true
                  m.requests.inc(verb + " " + path + " " + status.to_string())
                  m.latency.observe((clock.now() - start).to_double())
                }
                send(@moonasgi.Event::HttpResponseStart(status~, headers~))
              }
              other => send(other)
            }
          }
          inner(scope, receive, observed)
        }
        _ => inner(scope, receive, send)
      }
    }
  }
}
