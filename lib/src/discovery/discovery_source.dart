import 'discovered_server.dart';

/// Backend for the R-20 scan. The Settings screen depends only on this
/// interface — widget tests inject a fake (scan lists fakes / scan failure
/// → error state with manual entry still enabled), production uses
/// [MdnsOwnToneDiscovery].
///
/// Contract:
/// - completes with the hits found (possibly empty — "no servers" is a
///   result, not an error);
/// - throws [DiscoveryException] (or anything else) when the scan itself
///   failed;
/// - must never block manual entry: the caller puts its own ceiling on the
///   wait (the scan runs as a side panel, R-20).
abstract class DiscoverySource {
  Future<List<DiscoveredServer>> discover();
}

/// A scan that could not be run/completed at the backend level (socket bind
/// failed, no interfaces, …) — as distinct from a scan that ran and found
/// nothing (empty result).
class DiscoveryException implements Exception {
  const DiscoveryException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'DiscoveryException: $message${cause == null ? '' : ' ($cause)'}';
}
