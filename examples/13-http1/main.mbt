///|
/// The minimal HTTP/1 client codec the consul driver speaks to a consul agent:
/// build a close-delimited HTTP/1.0 request, then parse a raw response into its
/// status, headers, and Content-Length-trimmed body.
///
///     moon run examples/13-http1
#coverage.skip
fn main {
  try {
    // A GET with no body: request line, Host, and Connection: close.
    let get = @moonzero.http1_request(
      "GET", "/v1/health/service/greeter?passing=true", "127.0.0.1:8500", b"",
    )
    println("GET request:\n" + escape(@utf8.decode_lossy(get[:])))

    // A PUT carrying a JSON body sets Content-Type and Content-Length.
    let put = @moonzero.http1_request(
      "PUT",
      "/v1/agent/service/register",
      "127.0.0.1:8500",
      @utf8.encode("{\"ID\":\"greeter-1\"}"),
      content_type="application/json",
    )
    println("PUT request:\n" + escape(@utf8.decode_lossy(put[:])))

    // Parse a raw agent response; the body is trimmed to the declared length, so a
    // socket that read past the message drops the trailing bytes.
    let raw = @utf8.encode(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"status\":1}TRAILING",
    )
    let resp = @moonzero.http1_parse_response(raw)
    println("status: " + resp.status().to_string())
    println("content-type: " + header_or(resp, "content-type"))
    println("body: " + @utf8.decode_lossy(resp.body()[:]))
    println("absent header: " + header_or(resp, "x-missing"))
  } catch {
    Http1Error(msg) => println("http1 error: " + msg)
  }
}

///|
fn header_or(resp : @moonzero.Http1Response, name : String) -> String {
  match resp.header(name) {
    Some(v) => v
    None => "(none)"
  }
}

///|
/// Render a wire string with its CRLF framing visible.
fn escape(s : String) -> String {
  let sb = StringBuilder()
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == '\r' {
      sb.write_string("\\r")
    } else if c == '\n' {
      sb.write_string("\\n\n")
    } else {
      sb.write_char(c.to_int().unsafe_to_char())
    }
  }
  sb.to_string()
}
