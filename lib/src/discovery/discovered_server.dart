import '../core/server_config.dart';

/// One server found by a LAN scan (R-20): the mDNS instance name (the
/// server's display name — "My Music on hp-server"), the address to dial
/// (IP literal when an A record answered, mDNS hostname otherwise), and the
/// JSON-API port from the SRV record.
class DiscoveredServer {
  const DiscoveredServer({
    required this.name,
    required this.host,
    required this.port,
  });

  final String name;
  final String host;
  final int port;

  /// The config a tap on this hit pre-fills — fed through the *existing*
  /// R-01 connect flow, never a discovery-specific path.
  ServerConfig get config => ServerConfig(host: host, port: port);

  @override
  bool operator ==(Object other) =>
      other is DiscoveredServer &&
      other.name == name &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(name, host, port);

  @override
  String toString() => '$name ($host:$port)';
}
