// HTTP/1 client codec vectors: the request builder's bytes are checked against the
// exact message a consul agent receives, and real consul-shaped responses parse back
// to their status, headers, and body.

///|
test "http1 request: GET with no body" {
  assert_eq(
    http1_request("GET", "/v1/agent/services", "127.0.0.1:8500", b""),
    @utf8.encode(
      "GET /v1/agent/services HTTP/1.0\r\n" +
      "Host: 127.0.0.1:8500\r\n" +
      "Content-Length: 0\r\n" +
      "Connection: close\r\n\r\n",
    ),
  )
}

///|
test "http1 request: PUT with a JSON body and content type" {
  let body = b"{\"ID\":\"x\"}"
  assert_eq(
    http1_request(
      "PUT",
      "/v1/agent/service/register",
      "consul:8500",
      body,
      content_type="application/json",
    ),
    @utf8.encode(
      "PUT /v1/agent/service/register HTTP/1.0\r\n" +
      "Host: consul:8500\r\n" +
      "Content-Type: application/json\r\n" +
      "Content-Length: 10\r\n" +
      "Connection: close\r\n\r\n",
    ) +
    body,
  )
}

///|
test "http1 response: parse status, headers, and body" {
  let raw = @utf8.encode(
    "HTTP/1.1 200 OK\r\n" +
    "Content-Type: application/json\r\n" +
    "X-Consul-Index: 5\r\n" +
    "\r\n" +
    "[{\"Service\":{\"Address\":\"10.0.0.1\",\"Port\":9090}}]",
  )
  let resp = http1_parse_response(raw)
  assert_eq(resp.status(), 200)
  assert_eq(resp.header("content-type"), Some("application/json"))
  assert_eq(resp.header("X-Consul-Index"), Some("5"))
  assert_eq(resp.header("missing"), None)
  assert_eq(
    @utf8.decode_lossy(resp.body()[:]),
    "[{\"Service\":{\"Address\":\"10.0.0.1\",\"Port\":9090}}]",
  )
}

///|
test "http1 response: Content-Length trims trailing bytes" {
  let raw = @utf8.encode(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK-and-then-some",
  )
  let resp = http1_parse_response(raw)
  assert_eq(@utf8.decode_lossy(resp.body()[:]), "OK")
}

///|
test "http1 response: a 404 with an empty body" {
  let resp = http1_parse_response(
    @utf8.encode("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"),
  )
  assert_eq(resp.status(), 404)
  assert_eq(resp.body().length(), 0)
}

///|
test "http1 response: a malformed head raises" {
  let bad = try {
    let _ = http1_parse_response(b"garbage-no-terminator")
    false
  } catch {
    _ => true
  }
  assert_eq(bad, true)
}
