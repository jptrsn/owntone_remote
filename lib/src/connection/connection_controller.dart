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
  }) {
    _dioFactory = dioFactory ?? (options) => Dio(options);
    _wsFactory =
        wsFactory ??
        ((uri, subscriptions, b) =>
            WsClient(uri: uri, subscriptions: subscriptions, backoff: b));
    _backoff = backoff ?? Backoff();
    _logger = logger ?? Logger(printer: PrettyPrinter(methodCount: 0));
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
  Uri? _wsUri;

  Dio? _dio;
  OwntoneApi? _api;
  WsClient? _ws;
  StreamSubscription<String>? _wsStatusSub;
  StreamSubscription<List<String>>? _wsEventsSub;
  bool _firstWsOpen = true;

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
    _serverVersion = null;
    _setPhase(ConnectionPhase.connecting);

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
      _serverVersion = serverConfig['version'] as String?;
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
      final err = connectionErrorFromDio(e, config);
      _teardownClient();
      _errorMessage = err.message;
      _setPhase(ConnectionPhase.error);
    } catch (e) {
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
    _serverVersion = null;
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
  /// Runs once per reconnect attempt. A failed probe only downgrades a
  /// [ConnectionPhase.connected] state — and never after the WS reopened.
  Future<void> _probeServer() async {
    final api = _api;
    if (api == null) return;
    // Captured before the await: the probe is the reachability authority
    // only for the connection generation that scheduled it (see [_generation]).
    final generation = _generation;
    try {
      await api.getConfig();
      if (generation != _generation) return;
      if (_wsPhase != WsPhase.open) {
        _setPhase(ConnectionPhase.connected);
      }
    } on DioException catch (e) {
      if (generation != _generation) return;
      if (_wsPhase != WsPhase.open && _phase == ConnectionPhase.connected) {
        _logger.w('server probe failed (${e.error ?? e.type}) — offline');
        _setPhase(ConnectionPhase.offline);
      }
    }
  }

  void _teardownClient() {
    _generation++;
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
