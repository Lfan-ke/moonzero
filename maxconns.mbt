// Bounding the number of concurrent in-flight requests (← go-zero's `MaxConns` /
// `handler.MaxConnsHandler`): a semaphore of `max` permits. Each admitted HTTP request holds a
// permit for its whole duration and returns it when it finishes; a request that finds no permit
// free is answered `503 Service Unavailable` without reaching the app. This caps the work in flight
// so a burst of connections cannot exhaust the server, complementing the rate limiter (which bounds
// the arrival rate) and the breaker (which sheds on downstream failure).

///|
/// A permit pool of `max` concurrent slots (← go-zero's `syncx.Limit`).
pub struct MaxConns {
  max : Int
  mut in_flight : Int
}

///|
/// A pool admitting at most `max` requests at once.
pub fn MaxConns::new(max : Int) -> MaxConns {
  { max, in_flight: 0 }
}

///|
/// Take a permit if one is free (`TryBorrow`), returning whether it was taken.
pub fn MaxConns::try_acquire(self : MaxConns) -> Bool {
  if self.in_flight < self.max {
    self.in_flight = self.in_flight + 1
    true
  } else {
    false
  }
}

///|
/// Return a permit taken by `try_acquire` (`Return`).
pub fn MaxConns::release(self : MaxConns) -> Unit {
  if self.in_flight > 0 {
    self.in_flight = self.in_flight - 1
  }
}

///|
/// The number of requests currently holding a permit.
pub fn MaxConns::in_flight(self : MaxConns) -> Int {
  self.in_flight
}

///|
/// Max-connections middleware (← go-zero's `MaxConns`): hold a permit for the wrapped app's
/// duration, or answer `503 Service Unavailable` when every permit is taken. Non-HTTP scopes
/// (lifespan, websocket) pass through untouched.
pub fn max_conns(limit : MaxConns) -> Middleware {
  inner => {
    (scope, receive, send) => {
      match scope {
        Http(_) =>
          if limit.try_acquire() {
            inner(scope, receive, send)
            limit.release()
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
