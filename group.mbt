///|
/// Join a group prefix with a route path into a single, normalised path: at most
/// one slash between the two, a guaranteed leading slash, and `"/"` for the empty
/// result.
fn join_path(prefix : String, path : String) -> String {
  let mut end = prefix.length()
  while end > 0 && prefix[end - 1] == '/' {
    end = end - 1
  }
  let base = prefix[0:end].to_owned()
  let tail = if path.length() > 0 && path[0] != '/' { "/" + path } else { path }
  let joined = base + tail
  if joined.length() == 0 {
    "/"
  } else {
    joined
  }
}

///|
/// A route group (← go-zero's `RouteGroup`): registers a set of routes on an
/// underlying `moonapi.App` under a shared path prefix, so related endpoints
/// (e.g. everything under `/api/v1`) are declared without repeating the prefix.
pub struct Group {
  app : @moonapi.App
  prefix : String
}

///|
/// Open a group that prefixes every route it registers with `prefix` on `app`.
pub fn Group::new(app : @moonapi.App, prefix : String) -> Group {
  { app, prefix, }
}

///|
/// The prefix this group joins onto each registered route.
pub fn Group::prefix(self : Group) -> String {
  self.prefix
}

///|
/// Register a route for an explicit method under the group's prefix.
pub fn Group::route(
  self : Group,
  verb : @moonapi.Method,
  path : String,
  handler : @moonapi.ApiHandler,
  summary? : String = "",
) -> Unit {
  self.app.route(verb, join_path(self.prefix, path), handler, summary~)
}

///|
/// Register a `GET` route under the group's prefix.
pub fn Group::get(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary? : String = "",
) -> Unit {
  self.route(Get, path, handler, summary~)
}

///|
/// Register a `POST` route under the group's prefix.
pub fn Group::post(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary? : String = "",
) -> Unit {
  self.route(Post, path, handler, summary~)
}

///|
/// Register a `PUT` route under the group's prefix.
pub fn Group::put(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary? : String = "",
) -> Unit {
  self.route(Put, path, handler, summary~)
}

///|
/// Register a `PATCH` route under the group's prefix.
pub fn Group::patch(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary? : String = "",
) -> Unit {
  self.route(Patch, path, handler, summary~)
}

///|
/// Register a `DELETE` route under the group's prefix.
pub fn Group::delete(
  self : Group,
  path : String,
  handler : @moonapi.ApiHandler,
  summary? : String = "",
) -> Unit {
  self.route(Delete, path, handler, summary~)
}
