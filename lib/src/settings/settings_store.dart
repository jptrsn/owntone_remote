import 'package:shared_preferences/shared_preferences.dart';

import '../core/server_config.dart';

/// Persisted user settings (R-01). Only the configured server is stored;
/// the websocket port is discovered from `/api/config` each connect and
/// deliberately not persisted (a server config change must not be cached).
class SettingsStore {
  SettingsStore(this._prefs);

  static const _hostKey = 'server.host';
  static const _portKey = 'server.port';

  final SharedPreferences _prefs;

  static Future<SettingsStore> create() async =>
      SettingsStore(await SharedPreferences.getInstance());

  /// The saved server config, or null when nothing has been configured.
  ServerConfig? get config {
    final host = _prefs.getString(_hostKey);
    final port = _prefs.getInt(_portKey);
    if (host == null || host.trim().isEmpty || port == null) return null;
    return ServerConfig(host: host, port: port);
  }

  Future<void> save(ServerConfig config) {
    return Future.wait([
      _prefs.setString(_hostKey, config.host),
      _prefs.setInt(_portKey, config.port),
    ]);
  }
}
