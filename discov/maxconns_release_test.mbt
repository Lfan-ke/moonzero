///|
suberror InnerFailed

///|
/// A scope carrying nothing in particular — enough to drive a middleware.
fn plain_scope() -> @moonasgi.Scope {
  @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: "GET",
    scheme: "http",
    path: "/",
    raw_path: b"/",
    query_string: b"",
    root_path: "",
    headers: [],
    client: None,
    server: None,
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
}

///|
/// The limiter's permit has to come back on every path. It used to be released by a
/// trailing statement, so a request that raised — or was cancelled — kept its permit
/// forever and the limiter wedged shut, answering 503 to everything after it.
async test "max_conns returns the permit when the inner app raises" {
  let limit = @moonzero.MaxConns::new(1)
  let app = @moonzero.max_conns(limit)((_s, _r, _snd) => raise InnerFailed)
  let scope = plain_scope()
  let sent : Array[@moonasgi.Event] = []
  // With one permit and three failing requests, a leak would refuse the second and
  // third with 503; a correct release admits all three.
  for _ in 0..<3 {
    try
      app(scope, fn() { @moonasgi.Event::HttpDisconnect }, fn(e) {
        sent.push(e)
      })
    catch {
      InnerFailed => ()
      _ => fail("expected InnerFailed")
    } noraise {
      _ => fail("the inner app must raise")
    }
  }
  assert_eq(limit.in_flight(), 0)
  assert_eq(sent.length(), 0)
  assert_eq(limit.try_acquire(), true)
}
