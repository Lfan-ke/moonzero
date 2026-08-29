// Copyright 2026 Leo Cheng
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// Stand up a moonzero service — a `/api/v1/ping` route behind the metrics
/// middleware — drive a couple of requests through the onion, then render the
/// Prometheus exposition a `/metrics` scrape would read back.
///
///     moon run --target native examples/00-metrics
#coverage.skip
async fn main {
  let app = @moonapi.App::new()
  let api = @moonzero.Group::new(app, "/api/v1")
  api.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let m = @moonzero.ServerMetrics::new()
  let elapsed : Ref[Int64] = { val: 0L, }
  let clock = @moonzero.Clock::new(() => {
    let now = elapsed.val
    elapsed.val = now + 23L
    now
  })
  let conf = @moonzero.ServiceConf::new(
    name="greet",
    host="127.0.0.1",
    port=8888,
  )
  let onion = @moonzero.Server::new(conf, app)
    .use_(@moonzero.metrics(m, clock))
    .use_(@moonzero.logging)
  println(onion.describe())
  let handler = onion.to_asgi()
  for _ in 0..<2 {
    ping(handler, "GET", "/api/v1/ping")
  }
  println(m.to_exposition())
}

///|
/// Feed one request through an assembled ASGI onion in-process: a single-shot
/// body and a sink that drops the response events once the metrics middleware on
/// the response path has counted the request and timed it on the clock.
async fn ping(
  handler : @moonasgi.AsgiApp,
  verb : String,
  path : String,
) -> Unit {
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method=verb, path~),
  )
  let sent : Ref[Bool] = { val: false, }
  let receive : @moonasgi.Receive = () => {
    if sent.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      sent.val = true
      @moonasgi.Event::HttpRequest(body=b"", more_body=false)
    }
  }
  let sink : @moonasgi.Send = _event => ()
  handler(scope, receive, sink)
}
