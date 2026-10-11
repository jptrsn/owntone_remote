/// The user-configured connection target (R-01). The JSON API lives at
/// `http://<host>:<port>`; the websocket port is *discovered* from
/// `GET /api/config` and never stored.
class ServerConfig {
  const ServerConfig({required this.host, required this.port});

  static const int minPort = 1;
  static const int maxPort = 65535;

  final String host;
  final int port;

  /// Base URL of the JSON API.
  Uri get jsonBase => Uri(scheme: 'http', host: host, port: port, path: '/');

  /// Non-null when the config is invalid (settings-screen validation).
  String? get validationError {
    if (host.trim().isEmpty) return 'Enter a host name or IP address.';
    if (port < minPort || port > maxPort) {
      return 'Port must be between 1 and 65535.';
    }
    return null;
  }

  bool get isValid => validationError == null;

  @override
  bool operator ==(Object other) =>
      other is ServerConfig && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => '$host:$port';
}
