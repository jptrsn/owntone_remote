import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fakes/fake_ws_channel.dart';

/// Test-adversary suite for unit 009 (R-02 WS silent-drop hardening).
/// Regenerated from the contract, not from the existing suite:
///  * unit spec `.ai-dlc/remote-app/units/009-ws-silent-drop-hardening.md`
///    c1b (L71-72), c1d (L76), Goal-1 bound (L39-42), re-subscribe (L43-44);
///  * docs/API.md § Websocket (payload + "after every reconnect" send);
///  * dart:io ping semantics
///    https://api.dart.dev/stable/3.11.5/dart-io/WebSocket/pingInterval.html
///  * IOWebSocketChannel
///    https://pub.dev/documentation/web_socket_channel/3.0.3/io/IOWebSocketChannel-class.html
///  * flutter_test `test(timeout:)`
///    https://api.flutter.dev/flutter/flutter_test/test.html
///  * StreamController error/done delivery
///    https://api.dart.dev/stable/3.11.5/dart-async/StreamController-class.html
///
/// Fake-level (in-memory `FakeWsChannel`) only — the wire-level counterparts
/// run against the loopback RFC-6455 peer in
/// `ws_client_adversarial_wire_test.dart`.

final _uri = Uri.parse('ws://127.0.0.1:1/');

class _Recorder {
  _Recorder(WsClient ws) {
    statusSub = ws.status.listen(statuses.add);
    eventSub = ws.events.listen(events.add);
  }

  final List<String> statuses = [];
  final List<List<String>> events = [];
  late final StreamSubscription<String> statusSub;
  late final StreamSubscription<List<String>> eventSub;

  Future<void> dispose() async {
    await statusSub.cancel();
    await eventSub.cancel();
  }
}

class _ChannelScript {
  _ChannelScript(this.planned);

  /// Channels to hand out, in order; a `null` entry makes the factory throw
  /// (a connect that dies before a channel exists).
  final List<FakeWsChannel?> planned;
  final List<FakeWsChannel> created = [];
  final List<DateTime> createdTimes = [];
  int thrown = 0;

  WebSocketChannel create(Uri _) {
    if (planned.isEmpty) {
      throw StateError('channel script exhausted');
    }
    final channel = planned.removeAt(0);
    if (channel == null) {
      thrown++;
      throw const SocketException('factory boom (server down)');
    }
    created.add(channel);
    createdTimes.add(DateTime.now());
    return channel;
  }
}

Future<bool> _waitUntil(bool Function() cond, Duration max) async {
  final deadline = DateTime.now().add(max);
  while (!cond()) {
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return true;
}

Future<void> _settle([Duration d = const Duration(milliseconds: 60)]) async {
  await Future<void>.delayed(d);
  await pumpEventQueue();
}

WsClient _client(
  _ChannelScript script, {
  List<String> subscriptions = const ['player', 'volume'],
  Duration initialBackoff = const Duration(milliseconds: 50),
}) {
  return WsClient(
    uri: _uri,
    subscriptions: subscriptions,
    backoff: Backoff(initial: initialBackoff),
    channelFactory: script.create,
  );
}

void main() {
  group('unit 009 adversary — degenerate / malformed frames', () {
    test('malformed JSON, non-map payloads and zero-length notify arrays emit '
        'nothing and never schedule a reconnect; a valid frame still flows '
        'afterwards (docs/API.md § Websocket: events arrive as '
        '{ "notify": [...] } text frames)', () async {
      final script = _ChannelScript([FakeWsChannel()]);
      final ws = _client(script);
      final rec = _Recorder(ws);
      ws.start();
      await _settle();
      expect(rec.statuses, ['connecting', 'open']);
      final ch = script.created.single;

      const junk = <Object>[
        'not json at all', // FormatException path
        '{', // truncated JSON
        '[]', // JSON array, not a map
        'null', // JSON null
        '5', // JSON number
        '"a string"', // JSON string
        '{"notify": "player"}', // notify present but not a list
        '{"notify": {"a": 1}}', // notify is a map
        '{"notify": []}', // zero-length notify array
        '{"other": ["player"]}', // no notify key
        '{"notify": [42, null]}', // list of non-strings
      ];
      for (final frame in junk) {
        ch.serverSend(frame);
        await pumpEventQueue();
      }
      expect(
        rec.events,
        isEmpty,
        reason:
            'invalidation signals are event names only — garbage frames '
            'must not fabricate events (ws_client.dart _handleMessage)',
      );
      expect(
        rec.statuses,
        ['connecting', 'open'],
        reason:
            'the socket itself is healthy — a malformed frame must not '
            'drive the reconnect path (unit 009 Goal 1 reserves the '
            'reconnect path for a dead peer)',
      );

      ch.serverSend('{"notify":["player"]}');
      await pumpEventQueue();
      expect(rec.events, [
        ['player'],
      ], reason: 'the stream must stay usable after junk frames');
      ws.stop();
      await rec.dispose();
    });

    test(
      'a binary frame carrying JSON text is ignored without crashing or '
      'reconnecting (OwnTone speaks text JSON — docs/API.md § Websocket)',
      () async {
        final script = _ChannelScript([FakeWsChannel()]);
        final ws = _client(script);
        final rec = _Recorder(ws);
        ws.start();
        await _settle();
        final ch = script.created.single;

        ch.serverSend(Uint8List.fromList(utf8.encode('{"notify":["player"]}')));
        await pumpEventQueue();
        expect(rec.events, isEmpty, reason: 'binary ≠ the text JSON contract');
        expect(rec.statuses, ['connecting', 'open']);

        ch.serverSend('{"notify":["volume"]}');
        await pumpEventQueue();
        expect(rec.events, [
          ['volume'],
        ], reason: 'channel must survive a binary frame');
        ws.stop();
        await rec.dispose();
      },
    );

    test(
      'the on-connect subscribe payload is exactly {"notify":[...]} with the '
      'subscription order kept (docs/API.md § Websocket L144-147)',
      () async {
        const subs = ['queue', 'player', 'database'];
        final script = _ChannelScript([FakeWsChannel(), FakeWsChannel()]);
        final ws = _client(script, subscriptions: subs);
        final rec = _Recorder(ws);
        ws.start();
        await _settle();
        expect(
          script.created.first.clientSent,
          ['{"notify":["queue","player","database"]}'],
          reason: 'API.md prescribes {"notify": [...]} on connect',
        );

        // Reconnect → the *new* channel must receive the re-subscribe
        // (unit spec L43-44: "After reconnect: re-subscribe notify").
        script.created.first.serverClose();
        await _settle();
        expect(
          script.created[1].clientSent,
          ['{"notify":["queue","player","database"]}'],
          reason: 'API.md L144: send on connect *and after every reconnect*',
        );
        ws.stop();
        await rec.dispose();
      },
    );
  });

  group('unit 009 adversary — stop()/start() lifecycle (c1d)', () {
    test('stop() before start() is inert; a later start() still connects '
        '(degenerate lifecycle: stop on a never-started client)', () async {
      final script = _ChannelScript([FakeWsChannel()]);
      final ws = _client(script);
      final rec = _Recorder(ws);

      ws.stop();
      ws.stop();
      await _settle();
      expect(rec.statuses, ['stopped', 'stopped']);
      expect(script.created, isEmpty);

      ws.start();
      await _settle();
      expect(rec.statuses, [
        'stopped',
        'stopped',
        'connecting',
        'open',
      ], reason: 'an early stop() must not poison the client');
      expect(script.created.length, 1);
      ws.stop();
      await rec.dispose();
    });

    test('events, close and error arriving after stop() produce no events, no '
        'status past "stopped" and no new channel '
        '(task invariant "events after stop must not resurrect the client"; '
        'unit 009 c1d L76 "stop() cancels every timer — no reconnect after '
        'stop")', () async {
      final script = _ChannelScript([FakeWsChannel()]);
      final ws = _client(script, initialBackoff: const Duration(seconds: 5));
      final rec = _Recorder(ws);
      ws.start();
      await _settle();
      final ch = script.created.single;

      ws.stop();
      await _settle();
      expect(rec.statuses, ['connecting', 'open', 'stopped']);

      ch.serverSend('{"notify":["player"]}');
      ch.serverFail(); // fail first, then close — a closed controller
      ch.serverClose(); // rejects further events (Bad state), as expected
      await _settle(const Duration(milliseconds: 200));
      expect(
        rec.events,
        isEmpty,
        reason: 'the stream subscription is cancelled by stop()',
      );
      expect(rec.statuses, [
        'connecting',
        'open',
        'stopped',
      ], reason: 'nothing after stop() may move the client again');
      expect(
        script.created.length,
        1,
        reason: 'the post-stop close/error must not schedule a reconnect',
      );
      await rec.dispose();
    });

    test('start() twice then a single stop(): the leaked first channel cannot '
        'resurrect the client (no status past "stopped", no new attempt) — '
        'degenerate sequence the controller never performs, so the contract '
        'is read minimally: stop() must remain terminal', () async {
      final script = _ChannelScript([FakeWsChannel(), FakeWsChannel()]);
      final ws = _client(script, initialBackoff: const Duration(seconds: 5));
      final rec = _Recorder(ws);
      ws.start();
      ws.start();
      await _settle();
      expect(script.created.length, 2);
      expect(
        rec.statuses,
        ['connecting', 'connecting', 'open', 'open'],
        reason: 'each channel subscribes and opens once (D2 per connect)',
      );
      for (final ch in script.created) {
        expect(ch.clientSent, [
          '{"notify":["player","volume"]}',
        ], reason: 'both connects sent their subscribe');
      }

      ws.stop();
      await _settle();
      expect(rec.statuses.last, 'stopped');
      final marker = rec.statuses.length;

      // The leaked (overwritten, unclosed) channel 1 now misbehaves.
      script.created[0]
        ..serverFail()
        ..serverClose();
      script.created[1].serverClose();
      await _settle(const Duration(milliseconds: 300));
      expect(
        rec.statuses.sublist(marker),
        isEmpty,
        reason:
            'a leaked channel must not emit status after the terminal '
            '"stopped" (c1d)',
      );
      expect(
        script.created.length,
        2,
        reason: 'nor schedule a reconnect attempt after stop() (c1d)',
      );
      await rec.dispose();
    });

    test('stop() during the backoff window cancels the pending reconnect '
        '(unit 009 c1d L76, fake-level re-derivation)', () async {
      final script = _ChannelScript([FakeWsChannel()]);
      final ws = _client(script, initialBackoff: const Duration(seconds: 5));
      final rec = _Recorder(ws);
      ws.start();
      await _settle();
      script.created.single.serverClose();
      await _settle();
      expect(rec.statuses, ['connecting', 'open', 'reconnecting']);

      ws.stop();
      await _settle(const Duration(milliseconds: 100));
      expect(rec.statuses.last, 'stopped');
      final marker = rec.statuses.length;

      // Longer than the armed 5 s backoff delay would have elapsed for a
      // *smaller* armed timer; here the point is that the tracked timer
      // is cancelled: nothing new must appear.
      await _settle(const Duration(milliseconds: 200));
      expect(rec.statuses.sublist(marker), isEmpty);
      expect(script.created.length, 1);
      await rec.dispose();
    });
  });

  group('unit 009 adversary — ordering / interleavings (c1b)', () {
    test('close → reconnect → open emits each status exactly once, and the '
        'reconnect attempt lands inside [backoff, backoff+1s] of the close '
        '(c1b L71-72: "reconnecting + a reconnect attempt at the next backoff '
        'delay"; existing guard: no attempt *before* the delay)', () async {
      const initial = Duration(milliseconds: 300);
      final script = _ChannelScript([FakeWsChannel(), FakeWsChannel()]);
      final ws = _client(script, initialBackoff: initial);
      final rec = _Recorder(ws);
      ws.start();
      await _settle();

      final tClose = DateTime.now();
      script.created[0].serverClose();
      await _settle();
      expect(rec.statuses, ['connecting', 'open', 'reconnecting']);
      expect(script.created.length, 1, reason: 'no attempt before delay');

      expect(
        await _waitUntil(
          () => script.created.length == 2,
          const Duration(seconds: 3),
        ),
        isTrue,
        reason: 'a reconnect attempt must happen at the backoff delay',
      );
      final gap = script.createdTimes[1].difference(tClose);
      expect(
        gap,
        greaterThanOrEqualTo(const Duration(milliseconds: 280)),
        reason:
            'the attempt landed early — the backoff delay gate is '
            'supposed to hold (existing c1b guard)',
      );
      expect(
        gap,
        lessThanOrEqualTo(const Duration(seconds: 2)),
        reason:
            'the attempt must land at the next backoff delay '
            '(300 ms + slack), got $gap',
      );

      await _settle();
      expect(
        rec.statuses,
        ['connecting', 'open', 'reconnecting', 'connecting', 'open'],
        reason: 'no duplicate status emissions around one transition',
      );
      ws.stop();
      await rec.dispose();
    });

    test('error immediately after open, then a delayed onDone (the sequence '
        'dart:io/web_socket_channel can produce — error then done) must '
        'schedule exactly ONE reconnect attempt for the single disconnect '
        '(c1b L71-72: "a reconnect attempt"; c1d L76: "stop() cancels every '
        'timer" — a second, untracked timer would escape stop())', () async {
      final script = _ChannelScript([FakeWsChannel(), FakeWsChannel()]);
      final ws = _client(
        script,
        initialBackoff: const Duration(milliseconds: 200),
      );
      final rec = _Recorder(ws);
      ws.start();
      await _settle();
      final ch = script.created.single;

      ch.serverFail(); // stream error while open
      await Future<void>.delayed(const Duration(milliseconds: 250));
      ch.serverClose(); // ... and the done event that follows it

      await _settle();
      expect(
        rec.statuses.where((s) => s == 'reconnecting').length,
        1,
        reason:
            'one disconnect delivered as error→done must schedule one '
            'reconnect, not two (double scheduling also leaves an orphan '
            'timer that stop() cannot cancel — c1d)',
      );
      expect(
        script.created.length,
        2,
        reason: 'exactly one reconnect attempt for one disconnect (c1b)',
      );
      ws.stop();
      await rec.dispose();
    });

    test('a channel factory that throws on the first attempt still reconnects '
        'and opens on the next (degenerate: connect dies pre-channel; '
        'status path connecting → reconnecting → connecting → open)', () async {
      final script = _ChannelScript([null, FakeWsChannel()]);
      final ws = _client(
        script,
        initialBackoff: const Duration(milliseconds: 300),
      );
      final rec = _Recorder(ws);
      ws.start();
      await _settle(const Duration(milliseconds: 10));
      expect(rec.statuses, ['connecting', 'reconnecting']);
      expect(script.thrown, 1);

      expect(
        await _waitUntil(
          () => script.created.length == 1,
          const Duration(seconds: 3),
        ),
        isTrue,
        reason: 'a throwing factory must not kill the retry loop',
      );
      await _settle();
      expect(rec.statuses, [
        'connecting',
        'reconnecting',
        'connecting',
        'open',
      ]);
      ws.stop();
      await rec.dispose();
    });
  });

  group('unit 009 adversary — liveness-bound constants (Goal 1, c1a)', () {
    test(
      'kWsPingInterval honours the ≤ 10 s cap and keeps worst-case detection '
      '(2× interval) within the ≤ 30 s bound (unit spec L39-41: "detect a '
      'silent death in ≤ 30 s (e.g. 10 s pingInterval)"; c1a L69 "value '
      '≤ 10 s"; dart:io: pong must arrive within one interval — '
      'https://api.dart.dev/stable/3.11.5/dart-io/WebSocket/pingInterval.html)',
      () {
        expect(
          kWsPingInterval.inMilliseconds,
          lessThanOrEqualTo(10 * 1000),
          reason: 'c1a caps the configured pingInterval at 10 s',
        );
        expect(
          kWsPingInterval.inMilliseconds * 2,
          lessThanOrEqualTo(30 * 1000),
          reason:
              'silent death = last pong + one ping + one pong-timeout '
              '≤ 2× kWsPingInterval ≤ the unit\'s 30 s bound',
        );
      },
    );
  });
}
