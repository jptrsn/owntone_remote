import 'package:shared_preferences/shared_preferences.dart';

import '../core/server_config.dart';

/// Persisted user settings (R-01, R-14): the configured server and the
/// volume-rocker step. The websocket port is discovered from `/api/config`
/// each connect and deliberately not persisted (a server config change must
/// not be cached).
class SettingsStore {
  SettingsStore(this._prefs);

  static const _hostKey = 'server.host';
  static const _portKey = 'server.port';
  static const _rockerStepKey = 'rocker.step';

  /// R-14 bounds for the volume-rocker step (server-volume delta per press
  /// while foregrounded — R-06/D20 keeps it foreground-only).
  static const int minRockerStep = 1;
  static const int maxRockerStep = 10;
  static const int defaultRockerStep = 5;

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

  /// The volume-rocker step (R-14): read **per keypress** by the mirror
  /// handler, so a Settings change applies to the next press without a
  /// restart. Clamped on read *and* write — a hand-edited or legacy
  /// out-of-range value can never reach the server as a bigger step.
  int get rockerStep => (_prefs.getInt(_rockerStepKey) ?? defaultRockerStep)
      .clamp(minRockerStep, maxRockerStep);

  Future<void> saveRockerStep(int step) =>
      _prefs.setInt(_rockerStepKey, step.clamp(minRockerStep, maxRockerStep));
}
