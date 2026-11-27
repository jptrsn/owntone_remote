import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../api/backoff.dart';
import '../api/owntone_api.dart';
import '../api/ws_client.dart';
import '../core/connection_error.dart';
import '../core/server_config.dart';

/// Overall connection phase (R-01).
enum ConnectionPhase {
  /// No connection configured / explicit disconnect.
  idle,

  /// A connect attempt is in flight.
  connecting,

  /// The JSON API is reachable.
  connected,

  /// The server stopped being reachable while we had a connection
  /// (reconnect is running in the background).
  offline,

  /// A connect attempt failed; see [ConnectionController.errorMessage].
  error,
}

/// Websocket sub-state; only meaningful while [ConnectionPhase.connected]
/// (or [ConnectionPhase.offline], where it is [WsPhase.reconnecting]).
enum WsPhase {
  /// No WS expected yet (first handshake in flight) or none at all.
  none,

  /// Subscribed and receiving events.
  open,

  /// The connection dropped; backoff reconnect is running.
  reconnecting,

  /// The server reports `websocket_port: 0` — REST-only mode (R-02: WS
  /// failure never blocks REST control).
  disabled,
}

/// How often the controller re-probes REST while [ConnectionPhase.offline]
/// (fix, 2026-11-17 background/Doze wedge). While offline this timer — not
/// the WS status stream — is the banner's authority: a wedged WS client
/// (e.g. a black-holed handshake, see `kWsConnectTimeout` in ws_client.dart)
/// must never strand the UI at "Server unreachable — retrying" while the
/// server is actually reachable (R-01). The GET is trivial; 10 s matches the
/// backoff cap so the two paths feel the same.
const Duration kOfflineProbeInterval = Duration(seconds: 10);

/// The full event set this app subscribes to (R-02, docs/API.md).
const kWsSubscriptions = [
  'player',
  'volume',
  'outputs',
  'queue',
  'options',
  'database',
  'update',
];

typedef DioFactory = Dio Function(BaseOptions options);

typedef WsFactory =
    WsClient Function(Uri uri, List<String> subscriptions, Backoff backoff);

/// Owns the connection to one OwnTone server (R-01, R-02): REST
/// reachability, the websocket lifecycle (subscribe → backoff reconnect →
/// resubscribe), and the state the UI surfaces.
///
/// State machine (unit 001):
/// ```
/// idle → connecting → connected
/// connecting → error            (typed failure: DNS / refused / timeout / 401)
/// error → connecting            (automatic retry timer, network-y
///                                failures only — unit 3/#93)
/// connected → offline           (REST unreachable while the WS is down)
/// offline → connected           (REST reachable again)
/// connected → idle              (explicit disconnect)
/// ```
/// While the WS is down a REST probe runs on every reconnect attempt and
/// decides [ConnectionPhase.connected] vs [ConnectionPhase.offline]; the WS
/// never blocks REST (R-02). After every (re)open *after the first*,
/// [refetchAll] fires so slice controllers re-fetch.
class ConnectionController extends ChangeNotifier {
  ConnectionController({
    DioFactory? dioFactory,
    WsFactory? wsFactory,
    Backoff? backoff,
    Logger? logger,
    Duration offlineProbeInterval = kOfflineProbeInterval,
    Duration errorProbeInterval = kOfflineProbeInterval,
  }) {
    _dioFactory = dioFactory ?? (options) => Dio(options);
    _wsFactory =
        wsFactory ??
        ((uri, subscriptions, b) =>
            WsClient(uri: uri, subscriptions: subscriptions, backoff: b));
    _backoff = backoff ?? Backoff();
    _logger = logger ?? Logger(printer: PrettyPrinter(methodCount: 0));
    _offlineProbeInterval = offlineProbeInterval;
    _errorProbeInterval = errorProbeInterval;
  }

  late final DioFactory _dioFactory;
  late final WsFactory _wsFactory;
  late final Backoff _backoff;
  late final Logger _logger;

  final StreamController<List<String>> _events =
      StreamController<List<String>>.broadcast();
  final StreamController<void> _refetchAll = StreamController<void>.broadcast();

  ConnectionPhase _phase = ConnectionPhase.idle;
  WsPhase _wsPhase = WsPhase.none;
  String? _errorMessage;
  ServerConfig? _config;
  String? _serverVersion;
  String? _serverName;
  Uri? _wsUri;

  Dio? _dio;
  OwntoneApi? _api;
  WsClient? _ws;
  StreamSubscription<String>? _wsStatusSub;
  StreamSubscription<List<String>>? _wsEventsSub;
  bool _firstWsOpen = true;

  /// The safety-net probe while offline (see [kOfflineProbeInterval]):
  /// armed by [_setPhase] on entering [ConnectionPhase.offline], cancelled
  /// on leaving it (and in [_teardownClient]/[dispose]). Without it, the
  /// only offline→connected transitions rode the WS status stream — and a
  /// wedged `WsClient` (black-holed handshake) stops emitting on that
  /// stream, stranding the banner forever (user bug 2026-11-17).
  late final Duration _offlineProbeInterval;
  Timer? _offlineProbe;

  /// The recovery timer while [ConnectionPhase.error] (issue #93): a cold
  /// boot with the server unreachable landed in `error` and stayed there
  /// until the user tapped Retry — the offline probe above only exists in
  /// `offline`, and no connectivity listener exists. Armed by [_setPhase]
  /// when entering `error` from a network-y failure ([_errorAutoRetry]),
  /// cancelled on every other phase entry (and in [_teardownClient]/
  /// [dispose]). Without it, a rebooted phone + restarted server = dead
  /// remote until someone taps (same user-visible class as #81). Fires
  /// [retry] — not [_probeServer]: a failed attempt already tore the
  /// client down (`_api` null → the probe would no-op), and `retry` is
  /// exactly the path the host observation proved recovers
  /// (`error → connecting → connected`).
  late final Duration _errorProbeInterval;
  Timer? _errorRetry;

  /// Whether the failure that took us into [ConnectionPhase.error] was
  /// network-y (`dns`/`refused`/`timeout` — the reasons a black-holed
  /// network, down server, or dead DNS produce), i.e. whether the error
  /// recovery timer is eligible. Set by the `connectTo` failure catches,
  /// cleared by the `connectTo` prologue and [disconnect]: a 401 or a
  /// client bug must not spin a 10 s attempt loop.
  bool _errorAutoRetry = false;

  /// Single-flight state for [_probeServer]. Deliberately NOT reset by
  /// [_teardownClient]: an old-generation probe still awaiting `getConfig()`
  /// suppresses new probes until it resolves (bounded by dio's ≤15 s probe
  /// budget, and `Dio.close` cancels pending calls) — clearing the flags
  /// there would let the old probe's `finally` clobber the new generation's
  /// flag, which is worse than bounded suppression (review round 2).
  bool _probeInFlight = false;
  bool _probeTrailing = false;

  /// Bumped by every [_teardownClient] (connectTo start/failure, disconnect,
  /// dispose). An async continuation — the REST probe — must belong to the
  /// generation it started in before it may mutate [_phase]: without this, a
  /// probe in flight at teardown resolves into the shared instance and flips
  /// `idle → connected` / `error → connected`, edges the state machine
  /// (class doc) does not contain (unit 009 adversary round).
  int _generation = 0;

  ConnectionPhase get phase => _phase;
  WsPhase get wsPhase => _wsPhase;

  /// Human-readable failure text while [phase] is [ConnectionPhase.error].
  String? get errorMessage => _errorMessage;

  /// The config the last `connectTo` used (retry / settings pre-fill).
  ServerConfig? get config => _config;

  /// `version` from `/api/config` (null until the first successful connect).
  String? get serverVersion => _serverVersion;

  /// `library_name` from `/api/config` — the server's display name
  /// ("My Music on hp-server"), the R-21 drawer header's identity line
  /// (ReTune's "Connected To" row). Kept while [ConnectionPhase.offline]
  /// (identity survives a network drop); null until the first successful
  /// connect, cleared by [disconnect].
  String? get serverName => _serverName;

  /// The discovered websocket URL (`ws://host:<wsPort>/`), or null when the
  /// server has WS disabled (`websocket_port: 0`).
  Uri? get wsUri => _wsUri;

  bool get isConnected => _phase == ConnectionPhase.connected;
  bool get isWsDisabled => _wsPhase == WsPhase.disabled;

  /// OwnTone event names from the WS, e.g. `["volume"]` (R-02).
  Stream<List<String>> get events => _events.stream;

  /// Fires after a WS reconnect (not on the first open) — controllers
  /// re-fetch their full slice (R-02: full refetch on reconnect).
  Stream<void> get refetchAll => _refetchAll.stream;

  /// The REST client. Non-null from the first successful connect until
  /// [disconnect]; kept alive while [ConnectionPhase.offline] so probes and
  /// the later reconnect can reuse it.
  OwntoneApi? get api => _api;

  /// Connects to [config] (R-01), replacing any existing connection.
  /// Never throws — failures land in [phase]/[errorMessage].
  Future<void> connectTo(ServerConfig config) async {
    _teardownClient();
    _config = config;
    _errorMessage = null;
    _errorAutoRetry = false;
    _serverVersion = null;
    _serverName = null;
    _setPhase(ConnectionPhase.connecting);
    // Captured after the prologue teardown (which bumped it). The error
    // recovery timer (#93) makes attempts routinely in flight while the
    // user can still disconnect / start a newer connectTo — an unguarded
    // continuation then lands its phase into the newer generation, making
    // `disconnect()` non-final (T6) and letting a stale attempt flip
    // idle→error and re-arm the timer. Same guard [_probeServer] applies to
    // its probe continuations (see [_generation]).
    final generation = _generation;

    final options = BaseOptions(
      baseUrl: config.jsonBase.toString(),
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
    );
    final dio = _dioFactory(options);
    final api = OwntoneApi(dio: dio, baseUrl: config.jsonBase);
    _dio = dio;
    _api = api;
    try {
      final serverConfig = await api.getConfig();
      if (generation != _generation) return;
      _serverVersion = serverConfig['version'] as String?;
      _serverName = serverConfig['library_name'] as String?;
      final wsPort = (serverConfig['websocket_port'] as num?)?.toInt() ?? 0;
      if (wsPort > 0) {
        _wsUri = Uri(scheme: 'ws', host: config.host, port: wsPort, path: '/');
        final ws = _wsFactory(_wsUri!, kWsSubscriptions, _backoff);
        _ws = ws;
        _firstWsOpen = true;
        _setWsPhase(WsPhase.none);
        _wsStatusSub = ws.status.listen(_onWsStatus);
        _wsEventsSub = ws.events.listen(_events.add);
        ws.start();
      } else {
        // WS disabled on the server: REST-only mode (R-02).
        _wsUri = null;
        _setWsPhase(WsPhase.disabled);
      }
      _setPhase(ConnectionPhase.connected);
    } on DioException catch (e) {
      if (generation != _generation) return;
      final err = connectionErrorFromDio(e, config);
      // Network-y failures are indistinguishable from `offline` for
      // recovery purposes (issue #93) — the error timer may re-drive the
      // attempt. Auth/http/client-bug failures must keep Retry as the only
      // path (no 10 s credential hammering, no spin on our own bugs).
      _errorAutoRetry = switch (err.reason) {
        ConnectionErrorReason.dns ||
        ConnectionErrorReason.refused ||
        ConnectionErrorReason.timeout => true,
        ConnectionErrorReason.unauthorized ||
        ConnectionErrorReason.http ||
        ConnectionErrorReason.other => false,
      };
      _teardownClient();
      _errorMessage = err.message;
      _setPhase(ConnectionPhase.error);
    } catch (e) {
      if (generation != _generation) return;
      _errorAutoRetry = false;
      _teardownClient();
      _errorMessage = 'Connection failed: $e';
      _setPhase(ConnectionPhase.error);
    }
  }

  /// Re-attempts with the last config (error-screen retry).
  Future<void> retry() async {
    final config = _config;
    if (config != null) await connectTo(config);
  }

  /// Drops the connection (settings-screen "Disconnect" → idle).
  void disconnect() {
    _teardownClient();
    _errorMessage = null;
    _errorAutoRetry = false;
    _serverVersion = null;
    _serverName = null;
    _setPhase(ConnectionPhase.idle);
  }

  void _onWsStatus(String status) {
    switch (status) {
      case 'open':
        _setWsPhase(WsPhase.open);
        // A successful WS handshake proves the server is reachable again:
        // clear offline (the REST probe only runs while the WS is down).
        if (_phase == ConnectionPhase.offline) {
          _setPhase(ConnectionPhase.connected);
        }
        if (_firstWsOpen) {
          _firstWsOpen = false;
        } else {
          _logger.i('WS reconnected — full refetch');
          _refetchAll.add(null);
        }
      case 'reconnecting':
        _setWsPhase(WsPhase.reconnecting);
        unawaited(_probeServer());
      default:
        break;
    }
  }

  /// While the WS is down, REST decides reachability (offline banner, R-01).
  /// Runs on every WS reconnect attempt **and** on the offline retry timer
  /// (see [kOfflineProbeInterval]) — the timer is what recovers when the WS
  /// client has gone quiet (wedged handshake, 2026-11-17). A failed probe
  /// only downgrades a [ConnectionPhase.connected] state — and never after
  /// the WS reopened.
  ///
  /// Single-flight with a trailing run: a probe can outlive the interval
  /// (dio connect+receive budgets exceed it), and overlapping probes would
  /// make the phase last-*completion*-wins and flap the banner (pinned by
  /// test 5). Deviates from unit 011's do/while shape deliberately: the
  /// flag is released in the `finally` and the trailing run re-enters, so
  /// the trailing probe re-reads `_api`/`_generation` fresh. Unlike unit
  /// 011 (where a lost trailing fetch stranded a stale queue — and its
  /// trailing leg is pinned, `test/queue_screen_test.dart`), the trailing
  /// leg here is freshness-only: the offline `Timer.periodic` is the
  /// recovery authority, so no test pins the trailing run itself (verified
  /// surviving mutation, round 2) — deleting it only delays freshness by
  /// one backoff step, never recovery.
  Future<void> _probeServer() async {
    final api = _api;
    if (api == null) return;
    if (_probeInFlight) {
      _probeTrailing = true;
      return;
    }
    _probeInFlight = true;
    // Captured before the await: the probe is the reachability authority
    // only for the connection generation that scheduled it (see [_generation]).
    final generation = _generation;
    try {
      Object? probeError;
      try {
        await api.getConfig();
      } on Exception catch (e) {
        // `Exception`, not `Object`, and the try wraps ONLY the network call
        // (review round 1, 2026-11-17): the widening from `DioException` is
        // for probe failures — TimeoutException/SocketException arriving
        // un-wrapped still mean "not confirmed reachable". An `Error` (or
        // anything thrown by [_setPhase]'s listeners, which now sit outside
        // this catch) is a client bug and must reach the zone uncaught, not
        // be re-labelled "server probe failed" and flap the banner.
        probeError = e;
      }
      if (generation != _generation) return;
      final error = probeError;
      if (error == null) {
        if (_wsPhase != WsPhase.open) {
          _setPhase(ConnectionPhase.connected);
        }
      } else if (_wsPhase != WsPhase.open &&
          _phase == ConnectionPhase.connected) {
        _logger.w('server probe failed ($error) — offline');
        _setPhase(ConnectionPhase.offline);
      }
    } finally {
      _probeInFlight = false;
      if (_probeTrailing) {
        _probeTrailing = false;
        unawaited(_probeServer());
      }
    }
  }

  void _teardownClient() {
    _generation++;
    _offlineProbe?.cancel();
    _offlineProbe = null;
    _errorRetry?.cancel();
    _errorRetry = null;
    _wsStatusSub?.cancel();
    _wsStatusSub = null;
    _wsEventsSub?.cancel();
    _wsEventsSub = null;
    _ws?.stop();
    _ws = null;
    _dio?.close();
    _dio = null;
    _api = null;
    _wsUri = null;
    _setWsPhase(WsPhase.none);
  }

  void _setPhase(ConnectionPhase p) {
    if (_phase == p) return;
    _logger.i('connection: ${_phase.name} → ${p.name}');
    _phase = p;
    if (p == ConnectionPhase.offline) {
      // Safety net: while offline, the REST probe must keep running even
      // if the WS client has stopped reporting status (wedged handshake).
      _offlineProbe ??= Timer.periodic(_offlineProbeInterval, (_) {
        if (_phase == ConnectionPhase.offline) {
          unawaited(_probeServer());
        }
      });
    } else {
      _offlineProbe?.cancel();
      _offlineProbe = null;
    }
    if (p == ConnectionPhase.error && _errorAutoRetry) {
      // Safety net (issue #93): while in `error` after a network-y failure,
      // re-drive the connect attempt — without it the phase machine has no
      // `error → connecting` edge until someone taps Retry, so a phone that
      // booted while the server was down never recovers on its own.
      // `retry()` re-enters `connecting` (cancelling this timer before its
      // first await), and the failure catch re-arms it: a fixed-cadence
      // cycle, same feel as the offline probe. The callback re-checks the
      // phase so a tick racing a manual connect can never overlap it.
      _errorRetry ??= Timer.periodic(_errorProbeInterval, (_) {
        if (_phase == ConnectionPhase.error && _config != null) {
          unawaited(retry());
        }
      });
    } else {
      _errorRetry?.cancel();
      _errorRetry = null;
    }
    notifyListeners();
  }

  void _setWsPhase(WsPhase p) {
    if (_wsPhase == p) return;
    _logger.i('ws: ${_wsPhase.name} → ${p.name}');
    _wsPhase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _teardownClient();
    _events.close();
    _refetchAll.close();
    super.dispose();
  }
}
