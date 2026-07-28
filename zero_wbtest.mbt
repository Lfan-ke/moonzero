///|
test "config-driven server assembly + describe" {
  let app = @moonapi.App::new()
  app.get("/ping", _ctx => @moonapi.text(200, "pong"))
  let conf = ServiceConf::new(name="greet", host="127.0.0.1", port=8888)
  let server = Server::new(conf, app).use_(logging)
  assert_eq(server.describe(), "greet listening on 127.0.0.1:8888")
  let _ = server.to_asgi()
}

///|
test "default config" {
  let conf = ServiceConf::new()
  assert_eq(conf.name, "app")
  assert_eq(conf.host, "0.0.0.0")
  assert_eq(conf.port, 8888)
}
