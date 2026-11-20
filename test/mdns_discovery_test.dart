/// Pure-helper tests for the R-20 discovery layer — no network. Inputs are
/// the REAL advertisement captured in the 2026-11-20 `dns-sd` pre-flight
/// against 192.168.1.13 (see the transcript in
/// .ai-dlc/night-2026-11-19/reports/42.md): the server publishes its web
/// interface as `_http._tcp` with forked-daapd TXT markers, NOT under
/// `_owntone-server._tcp` (browsed empty), and the neighbouring
/// `_http._tcp` crowd (Volumio Kitchen on :80, `txtvers=1` only) must be
/// rejected by the fingerprint.
///
/// R-20.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/discovery/mdns_discovery.dart';

void main() {
  group('R-20 TXT fingerprint (isOwnToneTxt)', () {
    /// Verbatim TXT from the pre-flight `dns-sd -L "My Music on hp-server"
    /// _http._tcp local.` output.
    const realOwnToneTxt =
        'txtvers=1 Database ID=B20074A5 Machine ID=B20074A5 '
        'Machine Name=My Music on hp-server mtd-version=29.3 '
        'iTSh Version=131073 Version=196610 Password=false ffid=2d066dfc';

    test('accepts the server’s real _http._tcp TXT (ffid + mtd-version)', () {
      expect(isOwnToneTxt([realOwnToneTxt]), isTrue);
    });

    test('accepts a single marker (ffid only, or mtd-version only)', () {
      expect(isOwnToneTxt(['txtvers=1 ffid=2d066dfc']), isTrue);
      expect(isOwnToneTxt(['txtvers=1 mtd-version=29.3']), isTrue);
    });

    test('accepts the NEWLINE-joined form — how package:multicast_dns '
        'decodes a multi-string TXT RDATA (wire-verified 2026-11-20)', () {
      expect(
        isOwnToneTxt(['txtvers=1\nMachine Name=My Music\nffid=2d066dfc']),
        isTrue,
      );
      expect(isOwnToneTxt(['mtd-version=29.3\ntxtvers=1']), isTrue);
    });

    test('accepts markers split across multiple TXT records', () {
      expect(isOwnToneTxt(['txtvers=1', 'ffid=2d066dfc']), isTrue);
    });

    test('marker key match is case-insensitive', () {
      expect(isOwnToneTxt(['FFID=abc']), isTrue);
      expect(isOwnToneTxt(['MTD-Version=29.3']), isTrue);
    });

    test('rejects the neighbouring _http._tcp crowd: Volumio-style, '
        'generic-txtvers-only, and empty TXT', () {
      // Volumio Kitchen (pre-flight): TXT without any forked-daapd marker.
      expect(isOwnToneTxt(['txtvers=1']), isFalse);
      expect(isOwnToneTxt(['path=/index.html', 'ty=print']), isFalse);
      expect(isOwnToneTxt(<String>[]), isFalse);
    });

    test('rejects marker words that appear without a key-form "=" (a '
        'bare word in a value is not a marker)', () {
      expect(isOwnToneTxt(['Machine Name=server ffid edition']), isFalse);
      expect(isOwnToneTxt(['note=mtd-version is a thing']), isFalse);
    });
  });

  group('R-20 instance-name parsing (ownToneInstanceName)', () {
    test('strips the _http._tcp.local. suffix to the display name', () {
      expect(
        ownToneInstanceName('My Music on hp-server._http._tcp.local.'),
        'My Music on hp-server',
      );
    });

    test('tolerates the decoded (no trailing dot) and bare-suffix forms', () {
      expect(
        ownToneInstanceName('My Music on hp-server._http._tcp.local'),
        'My Music on hp-server',
      );
      expect(ownToneInstanceName('weird-name.local'), 'weird-name.local');
      expect(ownToneInstanceName('_http._tcp.local.'), '_http._tcp.local');
    });
  });
}
