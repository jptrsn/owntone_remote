import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import 'discovered_server.dart';
import 'discovery_source.dart';

/// The service type OwnTone ACTUALLY advertises, per the 2026-11-20 pre-
/// flight (`dns-sd -B` against 192.168.1.13): the server publishes its web
/// interface as `_http._tcp` (instance = the `/api/config` `library_name`,
/// SRV target `hp-server.local.:3689`, port cross-checked against
/// `/api/config`). It publishes NOTHING under `_owntone-server._tcp` or
/// `_owntone._tcp` (both browsed empty), and the `_dacp._tcp`/`_daap._tcp`
/// advertisements are the DAAP surface — out of scope (AGENTS.md §5), never
/// browsed here.
///
/// `_http._tcp` is a shared type (smart lamps, printers and Volumio
/// advertise on it too), so hits are only kept when their TXT records carry
/// the forked-daapd/OwnTone markers — see [isOwnToneTxt].
/// NO trailing dot on purpose: `LookupResolver.responseMatches` only
/// normalizes request names that end exactly in `local` (the package's own
/// examples use `_dartobservatory._tcp.local`) — `_http._tcp.local.` with a
/// trailing dot never matches a decoded record (decoded FQDNs carry no
/// trailing dot), so the browse would silently find nothing.
const String kOwnToneBrowseDomain = '_http._tcp.local';

/// TXT keys unique to forked-daapd/OwnTone Avahi announcements
/// (`ffid` = forked-daapd id, `mtd-version` = daemon version;
/// `owntone-version` is accepted for a future rename). A key match must sit
/// at record start or after a separator — a value merely *containing* one
/// of these words does not count. The separator set includes NEWLINE because
/// `package:multicast_dns` concatenates a multi-string TXT RDATA with
/// `writeln` (verified against the wire: the server publishes `txtvers=1`,
/// `…`, `ffid=…` as character-strings of ONE TXT RDATA, decoded as
/// newline-joined).
const List<String> kOwnToneTxtMarkerKeys = [
  'ffid',
  'mtd-version',
  'owntone-version',
];

/// True when any TXT record carries an OwnTone marker key (R-20 filter that
/// keeps the OwnTone server out of the neighbouring `_http._tcp` crowd —
/// e.g. Volumio Kitchen, TXT `txtvers=1`-only on :80, is rejected).
bool isOwnToneTxt(Iterable<String> txtRecords) {
  for (final record in txtRecords) {
    final lowered = record.toLowerCase();
    for (final key in kOwnToneTxtMarkerKeys) {
      if (RegExp('(^|[ \\n;])$key=').hasMatch(lowered)) return true;
    }
  }
  return false;
}

/// Display name from a PTR domain name:
/// `My Music on hp-server._http._tcp.local[.]` → `My Music on hp-server`.
/// Tolerates the decoded (no trailing dot) and the dns-sd-printed (trailing
/// dot) forms alike.
String ownToneInstanceName(String ptrDomainName) {
  var name = ptrDomainName;
  if (name.endsWith('.')) {
    name = name.substring(0, name.length - 1);
  }
  const suffix = '.$kOwnToneBrowseDomain';
  if (name.length > suffix.length && name.toLowerCase().endsWith(suffix)) {
    name = name.substring(0, name.length - suffix.length);
  }
  return name;
}

String _stripTrailingDot(String fqdn) =>
    fqdn.endsWith('.') ? fqdn.substring(0, fqdn.length - 1) : fqdn;

typedef MDnsClientFactory = MDnsClient Function();

/// The default transport, deliberate on two points (both measured on the
/// host LAN, 2026-11-20 — see the night-2026-11-19 report):
///
/// 1. **Ephemeral UDP source port, never 5353.** `adb` and Google Chrome
///    keep 5353 co-bound on this host; with `SO_REUSEPORT` the kernel
///    distributes each multicast *flow* to ONE co-bound socket, so a 5353
///    listener receives an unreliable subset (measured: the same browse
///    returned 13, then 9, then 0 answers). An ephemeral port is never a
///    candidate for those deliveries, and unicast replies to our queries
///    reach it directly.
/// 2. **QU (unicast-response) queries** — `isMulticast: false` at every
///    lookup below. RFC 6762 §6: with QU set, responders answer unicast to
///    the querier's address:port, which is what makes (1) work. Verified
///    against the real advertisement: the OwnTone server (Avahi) answers
///    QU with the full PTR+SRV+TXT+A response.
MDnsClient _defaultClient() => MDnsClient(
  rawDatagramSocketFactory:
      (
        host,
        port, {
        reuseAddress = true,
        reusePort = false,
        ttl = 1,
      }) async => RawDatagramSocket.bind(host, 0, reuseAddress: true, ttl: 255),
);

/// Production [DiscoverySource]: one-shot mDNS browse of [_http._tcp] over
/// `package:multicast_dns` (pure Dart — no platform plugin), keeping only
/// TXT-fingerprinted OwnTone hits and resolving each to host + port.
class MdnsOwnToneDiscovery implements DiscoverySource {
  MdnsOwnToneDiscovery({
    MDnsClientFactory? clientFactory,
    Duration browseWindow = const Duration(seconds: 3),
    Duration answerWindow = const Duration(seconds: 3),
  }) : _clientFactory = clientFactory ?? _defaultClient,
       _browseWindow = browseWindow,
       _answerWindow = answerWindow;

  final MDnsClientFactory _clientFactory;
  final Duration _browseWindow;
  final Duration _answerWindow;

  @override
  Future<List<DiscoveredServer>> discover() async {
    final client = _clientFactory();
    try {
      // onError: malformed/unexpected datagrams on the shared 5353 socket
      // (other apps' mDNS chatter) must never fault the scan.
      await client.start(onError: (Object _) {});
    } on Object catch (e) {
      throw DiscoveryException('Could not start the network scan.', e);
    }
    try {
      final instances = <String>{};
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(
          kOwnToneBrowseDomain,
          isMulticast: false,
        ),
        timeout: _browseWindow,
      )) {
        instances.add(ptr.domainName);
      }

      final found = <DiscoveredServer>{};
      // Fan out per instance: SRV (target+port) and TXT (fingerprint) in
      // parallel, A record only for hits that pass the fingerprint — the
      // shared `_http._tcp` crowd should not pay an A lookup each.
      await Future.wait(
        instances.map((fqdn) async {
          final srv = await _first<SrvResourceRecord>(
            client,
            ResourceRecordQuery.service(fqdn, isMulticast: false),
          );
          if (srv == null) return;
          final txt = <String>[];
          await for (final record in client.lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(fqdn, isMulticast: false),
            timeout: _answerWindow,
          )) {
            txt.add(record.text);
          }
          if (!isOwnToneTxt(txt)) return;
          var host = _stripTrailingDot(srv.target);
          final addr = await _first<IPAddressResourceRecord>(
            client,
            ResourceRecordQuery.addressIPv4(srv.target, isMulticast: false),
          );
          if (addr != null) host = addr.address.address;
          found.add(
            DiscoveredServer(
              name: ownToneInstanceName(fqdn),
              host: host,
              port: srv.port,
            ),
          );
        }),
      );

      final results = found.toList()
        ..sort((a, b) {
          final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          if (byName != 0) return byName;
          final byHost = a.host.compareTo(b.host);
          if (byHost != 0) return byHost;
          return a.port - b.port;
        });
      return results;
    } on DiscoveryException {
      rethrow;
    } on Object catch (e) {
      throw DiscoveryException('Network scan failed.', e);
    } finally {
      client.stop();
    }
  }

  Future<T?> _first<T extends ResourceRecord>(
    MDnsClient client,
    ResourceRecordQuery query,
  ) async {
    await for (final record in client.lookup<T>(query, timeout: _answerWindow)) {
      return record; // first answer wins (duplicates are common on 5353)
    }
    return null;
  }
}
