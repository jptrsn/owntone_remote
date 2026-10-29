import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/core/artwork_probe.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';

import 'fakes/fake_artwork_http_gated.dart';

/// R-03 unit 010 — TEST-ADVERSARY suite. Regenerated from the unit contract
/// (`.ai-dlc/remote-app/units/010-artwork-204-filter.md` Goal 1: a 204
/// resolves to the no-image branch at both fetch sites *without throwing*;
/// lines 48-50: non-204 failures keep today's `errorBuilder` behaviour;
/// lines 36-37: `withMaxWidth` untouched) — not from `artwork_204_test.dart`
/// (the executable contract, left untouched). These tests hunt inputs and
/// *sequences* the contract file does not cover: probe identity/caching
/// boundaries, degenerate answers, and stateful interleavings (URL swaps
/// racing a pending probe).
void main() {
  late GatedArtworkHttp http;

  setUpAll(() => http = GatedArtworkHttp.installOnce());
  tearDownAll(() => HttpOverrides.global = null);

  /// Exception/log sentinel — same three channels the contract file pins
  /// (debugPrint, FlutterError.onError chained to the binding handler, and
  /// the binding's pending exception). `restore()` must run before the test
  /// body returns (binding invariant on a modified debugPrint).
  ({List<String> logs, List<Object> frameworkErrors, void Function() restore})
  captureErrorOutput() {
    final logs = <String>[];
    final frameworkErrors = <Object>[];
    final prevPrint = debugPrint;
    final prevHandler = FlutterError.onError;
    debugPrint = (String? s, {int? wrapWidth}) => logs.add('$s');
    FlutterError.onError = (FlutterErrorDetails details) {
      frameworkErrors.add(details.exception);
      prevHandler?.call(details);
    };
    return (
      logs: logs,
      frameworkErrors: frameworkErrors,
      restore: () {
        debugPrint = prevPrint;
        FlutterError.onError = prevHandler;
      },
    );
  }

  Future<void> mountBox(WidgetTester tester, Uri? url, {Key? key}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: ArtworkBox(key: key, url: url),
          ),
        ),
      ),
    );
  }

  /// Let probe + (possible) image load + builders settle; same real-time
  /// windows the contract file uses (HTTP round-trip and decode run on the
  /// real event loop and need runAsync time).
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
  }

  void expectQuiet(
    WidgetTester tester,
    ({List<String> logs, List<Object> frameworkErrors, void Function() restore})
    out,
  ) {
    expect(out.logs, isEmpty, reason: 'no exception/error log for artwork');
    expect(out.frameworkErrors, isEmpty, reason: 'nothing reached onError');
    expect(tester.takeException(), isNull, reason: 'no pending exception');
  }

  group('probe identity / caching boundaries (R-03, unit 010)', () {
    test(
      'R-03 unit 010: 50 concurrent + repeat isNoArtwork callers share '
      'ONE GET per URL — the no-retry-storm clause (unit lines 90-93: '
      '"ONE GET per URL for the process lifetime... no retry storm")',
      () async {
        final id = nextArtworkId('storm');
        http.serve(id, status: 204);
        final url = artworkUri(id);
        final verdicts = await Future.wait(
          List.generate(50, (_) => ArtworkProbe.isNoArtwork(url)),
        );
        final again = await ArtworkProbe.isNoArtwork(url);
        expect(verdicts, everyElement(isTrue));
        expect(again, isTrue);
        expect(http.requestCount(id), 1, reason: 'exactly one probe GET, ever');
      },
    );

    testWidgets('R-03 unit 010: remounting the same URL (fresh screen entry) '
        'adds no probe GET — bounded request profile, no storm', (
      tester,
    ) async {
      final id = nextArtworkId('entry');
      http.serve(id, status: 204);
      final url = artworkUri(id);

      await mountBox(tester, url, key: const Key('e1'));
      await settle(tester);
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      // Entry 1 profile (unit Result "fetch profile" row): probe + the
      // adjudicated silent unknown-window Image GET.
      expect(http.requestCount(id), 2, reason: 'one probe + one image');

      // Fresh state = fresh screen entry (new key: same-key rebuild would
      // take didUpdateWidget's same-URL no-op instead).
      await mountBox(tester, url, key: const Key('e2'));
      await settle(tester);
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(
        http.requestCount(id),
        3,
        reason:
            'the remount adds only the (adjudicated) unknown-window Image '
            'GET — the probe cache held, so the profile stays linear',
      );
      expect(find.byType(Image), findsNothing, reason: 'still short-circuited');
    });

    testWidgets('R-03 unit 010: a probed 204 verdict STICKS when the server '
        'flips the same URL to 200 (tested interpretation: sticky verdict — '
        'unit Result: "a probed verdict... sticks for the session (server '
        'artwork is static per library entry)"; the spec does not require '
        're-checking a flip)', (tester) async {
      final id = nextArtworkId('flip');
      http.serve(id, status: 204);
      final url = artworkUri(id);

      await mountBox(tester, url, key: const Key('e1'));
      await settle(tester);
      expect(find.byType(Image), findsNothing);

      http.serve(id, status: 200, body: 'png'); // server flips its answer
      await mountBox(tester, url, key: const Key('e2'));
      await settle(tester);
      expect(
        find.byIcon(Icons.music_note),
        findsOneWidget,
        reason: 'the cached no-artwork verdict sticks (documented design)',
      );
      expect(find.byType(RawImage), findsNothing);
      expect(
        http.requestCount(id),
        3,
        reason: 'no re-probe on the flip: only the unknown-window Image GET',
      );
    });

    testWidgets('R-03 unit 010: swapping to a different URL re-probes — the '
        'new 200 URL renders its image (URL change re-probes, unit lines '
        '100/177: didUpdateWidget probes on URL change)', (tester) async {
      final idOld = nextArtworkId('old');
      final idNew = nextArtworkId('new');
      http.serve(idOld, status: 204);
      http.serve(idNew, status: 200, body: 'png');

      final boxKey = GlobalKey(); // same State across the swap (real path)
      await mountBox(tester, artworkUri(idOld), key: boxKey);
      await settle(tester);
      expect(find.byType(Image), findsNothing);

      await mountBox(tester, artworkUri(idNew), key: boxKey);
      await settle(tester);
      expect(find.byType(RawImage), findsOneWidget, reason: '200 renders');
      expect(find.byIcon(Icons.music_note), findsNothing);
      expect(http.requestCount(idNew), greaterThanOrEqualTo(2));
    });

    testWidgets('R-03 unit 010: a probe hanging past 3 s times out to '
        '`false` (today\'s behaviour preserved — Image stays mounted, '
        'errorBuilder decides) and the timed-out entry is EVICTED so the '
        'next screen entry re-probes (unit lines 92-93: "error/timeout '
        'entries are evicted so the next screen entry re-checks")', (
      tester,
    ) async {
      final id = nextArtworkId('slow');
      http.serve(id, status: 204);
      http.hang(id);
      final url = artworkUri(id);

      await mountBox(tester, url, key: const Key('e1'));
      await tester.pump();
      // Advance the fake clock past ArtworkProbe._timeout (3 s): the
      // `.timeout` timer lives in the test zone.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(
        find.byType(Image),
        findsOneWidget,
        reason: 'timeout must not take the no-image branch (false verdict)',
      );
      http.release(id); // the hung probe + image load now answer 204
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      expect(
        find.byIcon(Icons.music_note),
        findsOneWidget,
        reason: '204 image load → errorBuilder placeholder (today\'s path)',
      );
      expect(find.byType(Image), findsOneWidget);

      await mountBox(tester, url, key: const Key('e2'));
      await settle(tester);
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'the timed-out entry was evicted — re-probe now says 204',
      );
      expect(
        http.requestCount(id),
        4,
        reason: 'two probe attempts + two unknown-window image GETs',
      );
    });
  });

  group('degenerate answers (R-03, unit 010)', () {
    testWidgets('R-03 unit 010: a 204 that arrives WITH body bytes is still '
        'the normal no-image case — placeholder, no Image, quiet (Goal 1: '
        '"a 204 response must resolve to the placeholder... through the '
        'normal no-image branch — without throwing/logging")', (tester) async {
      final out = captureErrorOutput();
      final id = nextArtworkId('bytes');
      http.serve(id, status: 204, body: 'png'); // degenerate: 204 + bytes
      await mountBox(tester, artworkUri(id));
      await settle(tester);
      out.restore();
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing, reason: 'short-circuit branch');
      expect(find.byType(RawImage), findsNothing, reason: 'bytes never render');
      expectQuiet(tester, out);
    });

    testWidgets('R-03 unit 010: probe sees 404 → errorBuilder remains the '
        'decider — the Image stays mounted (today\'s error path intact, unit '
        'lines 48-50: "404 and other non-204 failures keep today\'s '
        'behaviour") and the placeholder shows quietly', (tester) async {
      final out = captureErrorOutput();
      final id = nextArtworkId('e404');
      http.serve(id, status: 404);
      await mountBox(tester, artworkUri(id));
      await settle(tester);
      out.restore();
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(
        find.byType(Image),
        findsOneWidget,
        reason: 'non-204 keeps the mounted-Image/errorBuilder shape',
      );
      expectQuiet(tester, out);
    });

    testWidgets('R-03 unit 010: probe host unreachable → verdict false is '
        'never cached as no-image — the image attempt still happens, the '
        'placeholder comes from errorBuilder, and the next entry re-probes '
        '(unit lines 92-93: "a probe that *throws*... is evicted so the '
        'next screen entry re-checks")', (tester) async {
      final out = captureErrorOutput();
      final id = nextArtworkId('dead');
      http.unreachable(id);
      final url = artworkUri(id);

      await mountBox(tester, url, key: const Key('e1'));
      await settle(tester);
      expect(find.byType(Image), findsOneWidget, reason: 'still attempted');
      expect(find.byIcon(Icons.music_note), findsOneWidget);

      await mountBox(tester, url, key: const Key('e2'));
      await settle(tester);
      out.restore();
      expect(
        http.requestCount(id),
        4,
        reason:
            'two entries × (probe attempt + image attempt) — failures '
            'evict, so a recovered host is re-checked next entry',
      );
      expect(find.byType(Image), findsOneWidget);
      expectQuiet(tester, out);
    });

    testWidgets('R-03 unit 010: an empty (relative) artwork Uri is handled '
        'as no usable URL — probe failure answers false, image attempt '
        'fails into errorBuilder, placeholder shows, nothing throws. '
        'ASSUMPTIONS: PlayerState.resolveArtwork maps the server\'s empty '
        '`artwork_url` to null upstream, so this is widget-level only', (
      tester,
    ) async {
      final out = captureErrorOutput();
      await mountBox(tester, Uri.parse(''));
      await settle(tester);
      out.restore();
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expectQuiet(tester, out);
    });
  });

  group('stateful interleavings (R-03, unit 010)', () {
    testWidgets('R-03 unit 010 c1b under race: a stale 204 probe for a '
        'REPLACED URL must not clobber the new URL\'s state — the swapped-in '
        '200 image keeps rendering (contract c1b: "a 200 with valid bytes '
        'renders the image"; unit line 609 continuation must be URL-scoped)', (
      tester,
    ) async {
      final out = captureErrorOutput();
      final idSlow = nextArtworkId('slowA');
      final idFast = nextArtworkId('fastB');
      http.serve(idSlow, status: 204);
      http.hang(idSlow);
      http.serve(idFast, status: 200, body: 'png');

      // GlobalKey: forces the SAME State across the URL swap — the real
      // app's path (now_playing_screen.dart mounts ArtworkBox at one
      // position, so a URL change goes through didUpdateWidget).
      final boxKey = GlobalKey();
      await mountBox(tester, artworkUri(idSlow), key: boxKey);
      await tester.pump(); // probe A pending (hung)
      await mountBox(tester, artworkUri(idFast), key: boxKey); // swap mid-probe
      await settle(tester); // B's probe + image resolve
      expect(
        find.byType(RawImage),
        findsOneWidget,
        reason: 'sanity: the 200 image is showing before the stale lands',
      );

      http.release(idSlow); // A's 204 continuation lands late
      await tester.pump();
      await tester.pump();
      out.restore();
      // NOTE: no expectQuiet here — A's adjudicated unknown-window Image GET
      // (unit Result: "the unknown-window Image GET is silent") was
      // unmounted by the swap before its response landed, so its
      // NetworkImageLoadException reaches FlutterError.onError with no
      // listener. That is pre-existing generic Image.network behaviour
      // (identical before unit 010), reported as an observation, not gated
      // by this state-correctness regression.
      expect(
        find.byType(RawImage),
        findsOneWidget,
        reason:
            'the stale 204 verdict for the REPLACED url '
            '$idSlow hid the current url $idFast\'s rendered image — '
            'a late probe continuation clobbered new-URL state',
      );
      expect(find.byIcon(Icons.music_note), findsNothing);
    });

    testWidgets('R-03 unit 010 Goal 1 under race: a late `false` verdict '
        'from a replaced URL must not re-mount the CURRENT URL\'s Image on '
        'an already-probed 204 — short-circuit-before-the-exception must '
        'survive the interleaving (unit lines 21-24 / c1a oracle: no mounted '
        'failing Image for a 204)', (tester) async {
      final idSlow = nextArtworkId('slowC');
      final id204 = nextArtworkId('d204');
      http.serve(idSlow, status: 200, body: 'png');
      http.hang(idSlow);
      http.serve(id204, status: 204);

      final boxKey = GlobalKey(); // same State across the swap (real path)
      await mountBox(tester, artworkUri(idSlow), key: boxKey);
      await tester.pump(); // probe C pending (hung)
      await mountBox(tester, artworkUri(id204), key: boxKey); // swap mid-probe
      await settle(tester);
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'sanity: D\'s 204 is short-circuited',
      );

      http.release(idSlow); // C's false continuation lands late
      await tester.pump();
      await tester.pump();
      expect(
        find.byType(Image),
        findsNothing,
        reason:
            'the stale false verdict for the REPLACED url '
            '$idSlow re-mounted the current url $id204\'s Image — a '
            'probed-204 URL is back on the Image.network failure branch',
      );
      expect(find.byIcon(Icons.music_note), findsOneWidget);
    });

    testWidgets('R-03 unit 010: unmounting mid-probe — the late verdict '
        'lands silently (mounted guard), no framework error', (tester) async {
      final out = captureErrorOutput();
      final id = nextArtworkId('unmount');
      http.serve(id, status: 204);
      http.hang(id);

      await mountBox(tester, artworkUri(id));
      await tester.pump();
      await tester.pumpWidget(
        const MaterialApp(home: SizedBox.shrink()), // unmount mid-probe
      );
      http.release(id);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      out.restore();
      expectQuiet(tester, out);
    });

    testWidgets('R-03 unit 010: ArtworkBox consumes an already-cached '
        'verdict for the same URL identity — one GET total, placeholder '
        'via the same no-image branch (shared probe cache across fetch '
        'sites; unit Result: verdicts are process-lifetime)', (tester) async {
      final id = nextArtworkId('shared');
      http.serve(id, status: 204);
      final url = artworkUri(id);
      // A prior fetch site (e.g. the mirror flow) probed the exact URL
      // ArtworkBox will probe (withMaxWidth-applied).
      final verdict = await ArtworkProbe.isNoArtwork(
        ArtworkBox.withMaxWidth(url)!,
      );
      expect(verdict, isTrue);
      expect(http.requestCount(id), 1, reason: 'the shared probe ran once');

      final out = captureErrorOutput();
      await mountBox(tester, url);
      await settle(tester);
      out.restore();
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(
        http.requestCount(id),
        2,
        reason: 'only the unknown-window Image GET added — no second probe',
      );
      expectQuiet(tester, out);
    });
  });
}
