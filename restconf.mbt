///|
/// Which of go-zero's built-in layers the engine installs (← `MiddlewaresConf`).
/// Every flag defaults to `true`, so an `etc/*.yaml` that says nothing about
/// middleware still gets the whole chain.
pub(all) struct MiddlewaresConf {
  trace : Bool
  log : Bool
  prometheus : Bool
  max_conns : Bool
  breaker : Bool
  shedding : Bool
  timeout : Bool
  recover : Bool
  metrics : Bool
  max_bytes : Bool
  gunzip : Bool
} derive(Eq, Debug)

///|
/// The full chain, which is what go-zero defaults to.
pub fn MiddlewaresConf::new(
  trace? : Bool = true,
  log? : Bool = true,
  prometheus? : Bool = true,
  max_conns? : Bool = true,
  breaker? : Bool = true,
  shedding? : Bool = true,
  timeout? : Bool = true,
  recover? : Bool = true,
  metrics? : Bool = true,
  max_bytes? : Bool = true,
  gunzip? : Bool = true,
) -> MiddlewaresConf {
  {
    trace,
    log,
    prometheus,
    max_conns,
    breaker,
    shedding,
    timeout,
    recover,
    metrics,
    max_bytes,
    gunzip,
  }
}

///|
/// One signing key the request-signature check would verify against (←
/// `rest.PrivateKeyConf`).
pub(all) struct PrivateKeyConf {
  fingerprint : String
  key_file : String
} derive(Eq, Debug)

///|
/// Request-signature settings (← `rest.SignatureConf`): whether an unsigned or
/// badly-signed request is refused outright, how long a signature stays valid,
/// and the keys it is checked against.
///
/// moonzero loads and validates this config — a strict service with no keys is
/// refused at assembly, as go-zero's `ErrSignatureConfig` does — but ships no
/// content-signature layer to consume it.
pub(all) struct SignatureConf {
  strict : Bool
  expiry_ms : Int64
  private_keys : Array[PrivateKeyConf]
} derive(Eq, Debug)

///|
/// Signature settings that verify nothing: not strict, go-zero's one-hour
/// expiry, no keys.
pub fn SignatureConf::new(
  strict? : Bool = false,
  expiry_ms? : Int64 = 3600000L,
  private_keys? : Array[PrivateKeyConf] = [],
) -> SignatureConf {
  { strict, expiry_ms, private_keys, }
}

///|
/// A REST service's configuration (← go-zero's `rest.RestConf`), embedding
/// `ServiceConf` the way go-zero's does. The name, bind address and request
/// timeout live on that embedded config — `host()`, `port()` and `timeout_ms()`
/// read them — and everything else here is RestConf's own.
///
/// `max_bytes` is an `Int` where go-zero uses `int64`: it is compared against a
/// request's `Content-Length`, and its own `range=` tag caps it at 32 MiB.
pub(all) struct RestConf {
  service : ServiceConf
  cert_file : String
  key_file : String
  verbose : Bool
  max_conns : Int
  max_bytes : Int
  cpu_threshold : Int64
  signature : SignatureConf
  middlewares : MiddlewaresConf
  trace_ignore_paths : Array[String]
}

///|
/// A REST config with go-zero's defaults: no TLS, not verbose, 10000 connections,
/// a 1 MiB body cap, a 90% CPU shed threshold, and the full middleware chain.
pub fn RestConf::new(
  service? : ServiceConf = ServiceConf::new(),
  cert_file? : String = "",
  key_file? : String = "",
  verbose? : Bool = false,
  max_conns? : Int = 10000,
  max_bytes? : Int = 1048576,
  cpu_threshold? : Int64 = 900L,
  signature? : SignatureConf = SignatureConf::new(),
  middlewares? : MiddlewaresConf = MiddlewaresConf::new(),
  trace_ignore_paths? : Array[String] = [],
) -> RestConf {
  {
    service,
    cert_file,
    key_file,
    verbose,
    max_conns,
    max_bytes,
    cpu_threshold,
    signature,
    middlewares,
    trace_ignore_paths,
  }
}

///|
/// The address the service binds.
pub fn RestConf::host(self : RestConf) -> String {
  self.service.host
}

///|
/// The port the service binds.
pub fn RestConf::port(self : RestConf) -> Int {
  self.service.port
}

///|
/// The per-request timeout budget in milliseconds; `0` disables it.
pub fn RestConf::timeout_ms(self : RestConf) -> Int {
  self.service.timeout_ms
}

///|
/// Whether TLS is configured — go-zero serves HTTPS once both files are named.
pub fn RestConf::tls(self : RestConf) -> Bool {
  self.cert_file.length() > 0 && self.key_file.length() > 0
}

///|
/// Load a `RestConf` from the YAML go-zero ships as `etc/*.yaml`. Keys are
/// matched canonically, `MOONZERO_*` env variables override the file, and a value
/// outside its `options=`/`range=` constraint is an error.
///
/// `Name` and `Port` carry no default, exactly as in go-zero: a rest service that
/// does not say who it is or where to listen fails to load.
pub fn RestConf::from_yaml(src : String) -> RestConf raise ConfigError {
  rest_conf_of(Conf::of_yaml(src))
}

///|
/// Load a `RestConf` from a JSON config string, with the same semantics as
/// `from_yaml`.
pub fn RestConf::from_json(src : String) -> RestConf raise ConfigError {
  rest_conf_of(Conf::of_json(src))
}

///|
/// Decode a `RestConf` from a loaded document.
fn rest_conf_of(c : Conf) -> RestConf raise ConfigError {
  let def = RestConf::new()
  {
    service: service_conf_of(c),
    cert_file: c.string("CertFile", default=def.cert_file),
    key_file: c.string("KeyFile", default=def.key_file),
    verbose: c.bool("Verbose", default=def.verbose),
    max_conns: c.int("MaxConns", default=def.max_conns),
    max_bytes: c.int("MaxBytes", default=def.max_bytes, range="[0:33554432]"),
    cpu_threshold: c.int64(
      "CpuThreshold",
      default=def.cpu_threshold,
      range="[0:1000]",
    ),
    signature: signature_of(c),
    middlewares: middlewares_of(c),
    trace_ignore_paths: c.strings(
      "TraceIgnorePaths",
      default=def.trace_ignore_paths,
    ),
  }
}

///|
/// Decode the `Signature` block.
fn signature_of(c : Conf) -> SignatureConf raise ConfigError {
  let def = SignatureConf::new()
  let keys : Array[PrivateKeyConf] = []
  for k in c.list("Signature.PrivateKeys") {
    keys.push({
      fingerprint: k.string("Fingerprint", default=""),
      key_file: k.string("KeyFile", default=""),
    })
  }
  {
    strict: c.bool("Signature.Strict", default=def.strict),
    expiry_ms: c.int64("Signature.Expiry", default=def.expiry_ms),
    private_keys: keys,
  }
}

///|
/// Decode the `Middlewares` block.
fn middlewares_of(c : Conf) -> MiddlewaresConf raise ConfigError {
  {
    trace: c.bool("Middlewares.Trace", default=true),
    log: c.bool("Middlewares.Log", default=true),
    prometheus: c.bool("Middlewares.Prometheus", default=true),
    max_conns: c.bool("Middlewares.MaxConns", default=true),
    breaker: c.bool("Middlewares.Breaker", default=true),
    shedding: c.bool("Middlewares.Shedding", default=true),
    timeout: c.bool("Middlewares.Timeout", default=true),
    recover: c.bool("Middlewares.Recover", default=true),
    metrics: c.bool("Middlewares.Metrics", default=true),
    max_bytes: c.bool("Middlewares.MaxBytes", default=true),
    gunzip: c.bool("Middlewares.Gunzip", default=true),
  }
}

///|
/// One layer of the assembled chain: go-zero's name for the handler, and the
/// middleware that stands in for it.
pub(all) struct Layer {
  name : String
  middleware : Middleware
}

///|
/// The engine that turns a `RestConf` into a runnable service (← go-zero's
/// `rest.engine`). It owns the state the built-in layers need — the connection
/// permits, the breaker window, the metric set, the shedder — so every request
/// shares one of each, and it installs exactly the layers `Middlewares` asks for.
pub struct RestEngine {
  conf : RestConf
  clock : Clock
  logger : Logger
  metrics : ServerMetrics
  conns : MaxConns
  circuit : Breaker
  shedder : Shedder
}

///|
/// Build the engine for `conf`, pointing the logger at the configured level (←
/// `ServiceConf.SetUp`'s `logx.SetUp`).
///
/// `usage` is the CPU meter the shedder reads, per mille. Raises `ConfigError`
/// for a strict signature config with no keys, which is go-zero's
/// `ErrSignatureConfig`.
pub fn RestEngine::new(
  conf : RestConf,
  clock? : Clock = Clock::system(),
  logger? : Logger,
  metrics? : ServerMetrics = ServerMetrics::new(),
  usage? : () -> Int64,
) -> RestEngine raise ConfigError {
  if conf.signature.strict && conf.signature.private_keys.length() == 0 {
    raise ConfigError("signature is strict but no private keys are configured")
  }
  let logger = logger.unwrap_or(logx)
  logger.set_level(conf.service.log_level)
  {
    conf,
    clock,
    logger,
    metrics,
    conns: MaxConns::new(conf.max_conns),
    circuit: Breaker::new(clock),
    shedder: Shedder::new(conf.cpu_threshold, usage?),
  }
}

///|
/// The config the engine was built from.
pub fn RestEngine::conf(self : RestEngine) -> RestConf {
  self.conf
}

///|
/// The metric set the `prometheus` layer records into — the same one
/// `mount_metrics` publishes.
pub fn RestEngine::metrics(self : RestEngine) -> ServerMetrics {
  self.metrics
}

///|
/// The chain the flags ask for, outermost first, in go-zero's
/// `buildChainWithNativeMiddlewares` order.
///
/// A layer whose configured value disables it is left out even when its flag is
/// on, as in go-zero: no shedder without a `CpuThreshold`, no timeout without a
/// budget, no body cap without a `MaxBytes`.
///
/// Two of go-zero's eleven flags install nothing here. `Metrics` is go-zero's
/// internal `stat.Metrics` sink, which moonzero has no counterpart for — its one
/// metric set is the Prometheus one the `Prometheus` flag installs. `Gunzip`
/// needs a DEFLATE decoder, which neither moonzero nor any dependency carries.
/// Both flags still load, so a go-zero config round-trips through `RestConf`.
pub fn RestEngine::layers(self : RestEngine) -> Array[Layer] {
  let mw = self.conf.middlewares
  let out : Array[Layer] = []
  if mw.trace {
    out.push({
      name: "trace",
      middleware: tracing(ignore_paths=self.conf.trace_ignore_paths),
    })
  }
  if mw.log {
    out.push({
      name: "log",
      middleware: structured_logging(self.clock, logger=self.logger),
    })
  }
  if mw.prometheus {
    out.push({
      name: "prometheus",
      middleware: metrics(self.metrics, self.clock),
    })
  }
  if mw.max_conns && self.conf.max_conns > 0 {
    out.push({ name: "maxConns", middleware: max_conns(self.conns), })
  }
  if mw.breaker {
    out.push({ name: "breaker", middleware: breaker(self.circuit), })
  }
  if mw.shedding && self.conf.cpu_threshold > 0L {
    out.push({ name: "shedding", middleware: shedding(self.shedder), })
  }
  if mw.timeout && self.conf.service.timeout_ms > 0 {
    out.push({
      name: "timeout",
      middleware: timeout(self.conf.service.timeout_ms.to_int64(), self.clock),
    })
  }
  if mw.recover {
    out.push({ name: "recover", middleware: inner => recovery(inner), })
  }
  if mw.max_bytes && self.conf.max_bytes > 0 {
    out.push({ name: "maxBytes", middleware: maxbytes(self.conf.max_bytes), })
  }
  out
}

///|
/// The names of the layers `layers` would install, outermost first.
pub fn RestEngine::names(self : RestEngine) -> Array[String] {
  self.layers().map(l => l.name)
}

///|
/// Assemble `app` under the configured chain. go-zero's `chain.New` names the
/// outermost handler first while `Server::use_` makes the most recent layer
/// outermost, so the list goes on back to front.
pub fn RestEngine::build(self : RestEngine, app : @moonapi.App) -> Server {
  let layers = self.layers()
  let mut server = Server::new(self.conf.service, app)
  for i = layers.length() - 1; i >= 0; i = i - 1 {
    server = server.use_(layers[i].middleware)
  }
  server
}
