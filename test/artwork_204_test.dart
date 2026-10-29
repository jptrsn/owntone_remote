import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';

import 'fakes/fake_artwork_http.dart';

/// R-03 unit 010 — a 204 from the artwork endpoint is the *normal* no-image
/// case, not an error. Today `Image.network` treats it as a failed load
/// (`NetworkImageLoadException: HTTP request failed, statusCode: 204`,
/// caught by `errorBuilder`) and on-device `flutter_cache_manager` logs
/// `Invalid statusCode: 204` for the audio_service `artUri` fetch
/// (SESSION-LOG 2026-10-26 item 4). These tests pin the specified
/// behaviour: 204 resolves through the same no-image branch as a null URL,
/// with zero exception/error-level output; every other status keeps
/// today's placeholder-via-error behaviour.
void main() {
  late FakeArtworkHttp http;

  setUpAll(() => http = FakeArtworkHttp.installOnce());
  tearDownAll(() => HttpOverrides.global = null);

  /// Collects everything that could count as "an exception or error-level
  /// log attributable to the artwork fetch": `debugPrint` (the hook
  /// flutter_cache_manager and the framework log through), `FlutterError
  /// .onError`, and the binding's pending exception. `FlutterError.onError`
  /// is chained, not replaced — the binding's own handler is what feeds
  /// `takeException` (api.flutter.dev/flutter/foundation/FlutterError/onError.html).
  /// The binding's invariant check rejects a test that ends with a
  /// modified `debugPrint`, so every test must call `restore()` before its
  /// body returns.
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

  /// Mount [ArtworkBox] and let the (stubbed) fetch settle — the same
  /// real-time windows `now_playing_screen_test.dart` uses for artwork:
  /// the HTTP round-trip and the image decode run on the real event loop
  /// and need `runAsync` time; the builders need a `pump` per window.
  Future<void> pumpArtwork(WidgetTester tester, Uri? url) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(width: 300, height: 300, child: ArtworkBox(url: url)),
        ),
      ),
    );
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
    expect(
      out.frameworkErrors,
      isEmpty,
      reason: 'nothing reached FlutterError.onError',
    );
    expect(tester.takeException(), isNull, reason: 'no pending exception');
  }

  group('artwork HTTP status handling (R-03, unit 010)', () {
    // c1a — RED until the fix: today the 204 goes through
    // Image.network's error branch (the `Image` widget is mounted and its
    // errorBuilder renders the placeholder), instead of resolving to the
    // no-image result like a null URL.
    testWidgets('R-03 unit 010 c1a: a 204 artwork answer renders the '
        'music_note placeholder through the normal no-image branch, with no '
        'exception and no "Invalid statusCode: 204" log', (tester) async {
      final out = captureErrorOutput();
      await pumpArtwork(tester, artworkUrl('c1a', status: 204));
      out.restore();

      expect(
        find.byIcon(Icons.music_note),
        findsOneWidget,
        reason: '204 → placeholder (R-03 "artwork with fallback")',
      );
      // The specified branch is the `else` (no-Image) branch — the unit
      // requires short-circuiting the 204 *before it becomes an exception*,
      // so no failing Image.network load may remain mounted for it.
      expect(
        find.byType(Image),
        findsNothing,
        reason:
            'a 204 must not take Image.network\'s failure branch '
            '(unit 010 Goal: "short-circuit the 204 before it becomes '
            'an exception")',
      );
      expect(find.byType(RawImage), findsNothing, reason: 'no partial image');
      expectQuiet(tester, out);
    });

    // c1b — pre-green guard (passes today): demoting 204 must not break
    // the genuine success path.
    testWidgets('R-03 unit 010 c1b: a 200 artwork answer with valid bytes '
        'renders the image, not the placeholder', (tester) async {
      final out = captureErrorOutput();
      await pumpArtwork(tester, artworkUrl('c1b', status: 200, body: 'png'));
      out.restore();

      expect(
        find.byType(RawImage),
        findsOneWidget,
        reason: '200 + decodable bytes → the image itself',
      );
      expect(
        find.byIcon(Icons.music_note),
        findsNothing,
        reason: 'no placeholder when the image rendered',
      );
      expectQuiet(tester, out);
    });

    // c1c — pre-green guards (pass today): non-204 failures keep today's
    // placeholder behaviour.
    for (final status in const [404, 500]) {
      testWidgets('R-03 unit 010 c1c: an HTTP $status artwork answer still '
          'renders the placeholder (non-204 errors unchanged)', (tester) async {
        final out = captureErrorOutput();
        await pumpArtwork(tester, artworkUrl('c1c-', status: status));
        out.restore();

        expect(
          find.byIcon(Icons.music_note),
          findsOneWidget,
          reason: '$status → placeholder',
        );
        expect(find.byType(RawImage), findsNothing);
        expect(tester.takeException(), isNull);
        expect(out.frameworkErrors, isEmpty);
      });
    }

    testWidgets('R-03 unit 010 c1c: a 200 artwork answer with undecodable '
        'bytes still renders the placeholder (genuine error, not demoted)', (
      tester,
    ) async {
      final out = captureErrorOutput();
      await pumpArtwork(
        tester,
        artworkUrl('c1c-garbage', status: 200, body: 'garbage'),
      );
      out.restore();

      expect(
        find.byIcon(Icons.music_note),
        findsOneWidget,
        reason: 'garbage bytes → placeholder',
      );
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
      expect(out.frameworkErrors, isEmpty);
    });

    // c1d — pre-green guard (passes today): the null-URL branch is the
    // target shape for 204 and must not be restyled.
    testWidgets('R-03 unit 010 c1d: a null artwork URL renders the '
        'placeholder directly (no fetch)', (tester) async {
      final out = captureErrorOutput();
      await pumpArtwork(tester, null);
      out.restore();

      expect(
        find.byIcon(Icons.music_note),
        findsOneWidget,
        reason: 'null URL → placeholder',
      );
      expect(find.byType(Image), findsNothing, reason: 'no Image mounted');
      expect(find.byType(RawImage), findsNothing);
      expectQuiet(tester, out);
    });

    // c1e — pre-green guard (passes today) for the *fetch path*: the
    // unit-005a downsize contract must survive the 204 filter (the pure
    // function is covered in test/artwork_url_test.dart).
    testWidgets('R-03 unit 010 c1e: the artwork fetch requests the '
        'maxwidth=600 downsize URL (unit 005a contract)', (tester) async {
      final before = http.requests.length;
      await pumpArtwork(tester, artworkUrl('c1e', status: 204));

      final issued = http.requests.skip(before);
      expect(
        issued.where((r) => r.contains('/artwork/item/c1e')),
        isNotEmpty,
        reason: 'ArtworkBox must actually request the artwork URL',
      );
      expect(
        issued.where(
          (r) => r.contains('/artwork/item/c1e') && r.contains('maxwidth=600'),
        ),
        isNotEmpty,
        reason: 'every artwork request carries maxwidth=600',
      );
    });
  });
}
