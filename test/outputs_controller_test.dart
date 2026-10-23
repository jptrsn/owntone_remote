import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// A tiny stateful OwnTone outputs server (unit 004): GETs reflect the
/// store, `PUT /api/outputs/set` applies the full id list from the JSON
/// body, `PUT /api/outputs/{id}` applies selected/pin/volume, and
/// `PUT /api/player/volume?output_id=` sets one output's volume.
class OutputsServer {
  OutputsServer();

  /// Wire-shaped store: id, name, type, selected, has_password,
  /// needs_auth_key, volume.
  final List<Map<String, dynamic>> store = [
    {
      'id': 'a',
      'name': 'A',
      'type': 'Chromecast',
      'selected': true,
      'has_password': false,
      'needs_auth_key': false,
      'volume': 50,
    },
    {
      'id': 'b',
      'name': 'B',
      'type': 'Chromecast',
      'selected': false,
      'has_password': false,
      'needs_auth_key': false,
      'volume': 60,
    },
    {
      'id': 'c',
      'name': 'C',
      'type': 'AirPlay 1',
      'selected': false,
      'has_password': true,
      'needs_auth_key': false,
      'volume': 70,
    },
  ];

  /// Full id lists received at `/api/outputs/set`, in order.
  final List<List<String>> setCalls = [];

  /// Bodies received at `/api/outputs/{id}`, in order.
  final List<Map<String, dynamic>> perOutputBodies = [];

  /// The `output_id` values seen on `/api/player/volume`, in order.
  final List<String> volumeCalls = [];

  /// When non-null, PUTs to this path fail with [failStatus].
  String? failPutPath;
  int failStatus = 500;

  /// When true, the next PIN-bearing enable answers 400 (wrong PIN).
  bool rejectNextPin = false;

  Response<dynamic> handle(RequestOptions o) {
    final p = o.path;
    if (o.method == 'GET') {
      switch (p) {
        case '/api/config':
          return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
        case '/api/outputs':
          return jsonResponse(o, {'outputs': store});
        default:
          return jsonResponse(o, <String, dynamic>{});
      }
    }
    if (p == failPutPath) {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: o, statusCode: failStatus),
      );
    }
    switch (p) {
      case '/api/outputs/set':
        final body = o.data as Map<String, dynamic>;
        final ids = (body['outputs'] as List).cast<String>().toList();
        setCalls.add(ids);
        for (final out in store) {
          out['selected'] = ids.contains(out['id']!);
        }
        return Response(requestOptions: o, statusCode: 204);
      case '/api/player/volume':
        final q = o.queryParameters.map((k, v) => MapEntry(k, v.toString()));
        final outId = q['output_id'];
        if (outId == null) {
          return Response(requestOptions: o, statusCode: 204); // master
        }
        volumeCalls.add(outId);
        final out = store.firstWhere((s) => s['id'] == outId);
        out['volume'] = int.parse(q['volume']!).clamp(0, 100);
        return Response(requestOptions: o, statusCode: 204);
      default:
        if (p.startsWith('/api/outputs/')) {
          final body = (o.data as Map<String, dynamic>).cast<String, dynamic>();
          perOutputBodies.add(body);
          if (rejectNextPin &&
              body['selected'] == true &&
              body['pin'] != null) {
            rejectNextPin = false;
            throw DioException(
              requestOptions: o,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: o, statusCode: 400),
            );
          }
          final outId = p.substring('/api/outputs/'.length);
          final out = store.firstWhere((s) => s['id'] == outId);
          if (body['selected'] != null) out['selected'] = body['selected'];
          if (body['volume'] != null) out['volume'] = body['volume'];
          return Response(requestOptions: o, statusCode: 204);
        }
        return Response(requestOptions: o, statusCode: 204);
    }
  }
}

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// R-09 (unit 004): selection toggles go out as exactly one
/// `PUT /api/outputs/set` with the full id list; the PIN flow uses
/// `PUT /api/outputs/{id}` with `selected: true, pin`; per-output volume
/// uses `PUT /api/player/volume?output_id=`; failures roll back with a
/// typed error.
void main() {
  late OutputsServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late OutputsController outputs;

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() async {
    server = OutputsServer();
    adapter = ScriptedAdapter(responder: server.handle);
    channels = [];
    conn = ConnectionController(
      dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
      wsFactory: (uri, subscriptions, backoff) => WsClient(
        uri: uri,
        subscriptions: subscriptions,
        backoff: Backoff(
          initial: const Duration(milliseconds: 5),
          maximum: const Duration(milliseconds: 20),
        ),
        channelFactory: (u) {
          final c = FakeWsChannel();
          channels.add(c);
          return c;
        },
      ),
    );
    outputs = OutputsController(connection: conn);
    await outputs.init();
    await conn.connectTo(_cfg);
    await pump();
  });

  tearDown(() {
    outputs.dispose();
    conn.dispose();
  });

  List<String> setRequests() => adapter.requests
      .where((r) => r.startsWith('PUT /api/outputs/set'))
      .toList();

  test('first fetch loads the list with wire fields (C1 shape)', () {
    expect(outputs.outputs, hasLength(3));
    expect(outputs.outputs[0].id, 'a');
    expect(outputs.outputs[0].selected, isTrue);
    expect(outputs.outputs[2].type, 'AirPlay 1');
    expect(outputs.outputs[2].hasPassword, isTrue);
    expect(outputs.outputs.map((o) => o.volume), [50, 60, 70]);
    expect(outputs.selected.map((o) => o.id), ['a']);
    expect(outputs.hasLoaded, isTrue);
  });

  test(
    'toggle ON: exactly one PUT /api/outputs/set, full id list (R-09)',
    () async {
      final pending = outputs.toggle('b');
      // Optimistic: the checkbox flips before the response.
      expect(outputs.outputs.firstWhere((o) => o.id == 'b').selected, isTrue);
      await pending;

      expect(setRequests(), hasLength(1), reason: 'one call, not N toggles');
      expect(
        adapter.requests,
        isNot(contains(contains('PUT /api/outputs/b'))),
        reason: 'no per-output PUT for a plain toggle',
      );
      expect(server.setCalls.single, [
        'a',
        'b',
      ], reason: 'full id list, server order');
      // Reconciled with the server by the confirming refetch.
      expect(outputs.outputs.firstWhere((o) => o.id == 'b').selected, isTrue);
      expect(outputs.outputs.firstWhere((o) => o.id == 'a').selected, isTrue);
    },
  );

  test('toggle OFF: the id leaves the full list', () async {
    await outputs.toggle('a');
    expect(server.setCalls.single, <String>[], reason: 'empty set is legal');
    expect(outputs.outputs.firstWhere((o) => o.id == 'a').selected, isFalse);
  });

  test('multi-select: disabling one of two keeps the other selected', () async {
    await outputs.toggle('b'); // a + b selected
    expect(server.setCalls.single, ['a', 'b']);
    await outputs.toggle('b'); // back to a only
    expect(server.setCalls[1], ['a']);
    expect(outputs.selected.map((o) => o.id), ['a']);
  });

  test('toggle on 5xx: optimistic flip rolls back + typed error', () async {
    server.failPutPath = '/api/outputs/set';

    final pending = outputs.toggle('b');
    expect(outputs.outputs.firstWhere((o) => o.id == 'b').selected, isTrue);
    expect(await pending, isFalse);

    expect(
      outputs.outputs.firstWhere((o) => o.id == 'b').selected,
      isFalse,
      reason: 'rolled back',
    );
    expect(server.setCalls, isEmpty, reason: 'server never saw the call');
    expect(outputs.actionError, contains('Outputs failed'));
    expect(outputs.actionError, contains('HTTP 500'));
    expect(outputs.actionErrorSeq, 1);

    // Recovery: same action succeeds and reconciles.
    server.failPutPath = null;
    expect(await outputs.toggle('b'), isTrue);
    expect(outputs.actionError, isNull);
  });

  test('repeated failures bump the seq (same message re-toasts)', () async {
    server.failPutPath = '/api/outputs/set';
    await outputs.toggle('b');
    await outputs.toggle('a');
    expect(outputs.actionErrorSeq, 2);
  });

  test(
    'enableWithPin: PUT /api/outputs/{id} with selected + pin (R-09)',
    () async {
      final pending = outputs.enableWithPin('c', '1234');
      expect(outputs.outputs.firstWhere((o) => o.id == 'c').selected, isTrue);
      expect(await pending, isTrue);

      expect(adapter.requests, contains('PUT /api/outputs/c'));
      expect(setRequests(), isEmpty, reason: 'PIN path never uses /set');
      final body = server.perOutputBodies.single;
      expect(body['selected'], isTrue);
      expect(body['pin'], '1234');
      expect(outputs.outputs.firstWhere((o) => o.id == 'c').selected, isTrue);
    },
  );

  test(
    'wrong PIN (4xx): output stays disabled, error surfaced (R-09)',
    () async {
      server.rejectNextPin = true;
      final pending = outputs.enableWithPin('c', '0000');
      expect(await pending, isFalse);

      expect(
        outputs.outputs.firstWhere((o) => o.id == 'c').selected,
        isFalse,
        reason: 'stays disabled + rolled back',
      );
      expect(outputs.actionError, contains('Unlock failed'));
      expect(outputs.actionError, contains('HTTP 400'));
    },
  );

  test('setOutputVolume: PUT /api/player/volume?output_id (R-09)', () async {
    final pending = outputs.setOutputVolume('b', 62);
    // Optimistic: the row label moves before the response.
    expect(outputs.outputs.firstWhere((o) => o.id == 'b').volume, 62);
    expect(await pending, isTrue);

    expect(
      adapter.requests,
      contains('PUT /api/player/volume?volume=62&output_id=b'),
    );
    expect(server.volumeCalls, ['b']);
    expect(
      outputs.outputs.firstWhere((o) => o.id == 'b').volume,
      62,
      reason: 'confirmed by the refetch',
    );
  });

  test('setOutputVolume on 5xx rolls the value back', () async {
    server.failPutPath = '/api/player/volume';
    final pending = outputs.setOutputVolume('b', 10);
    expect(outputs.outputs.firstWhere((o) => o.id == 'b').volume, 10);
    expect(await pending, isFalse);
    expect(outputs.outputs.firstWhere((o) => o.id == 'b').volume, 60);
    expect(outputs.actionError, contains('Output volume failed'));
  });

  test('WS outputs event refetches the slice (R-02)', () async {
    // Someone else (the server web UI) selected an output behind our backs.
    server.store.firstWhere((s) => s['id'] == 'b')['selected'] = true;
    channels.single.serverSend('{"notify":["outputs"]}');
    await pump();

    expect(outputs.outputs.firstWhere((o) => o.id == 'b').selected, isTrue);
  });

  test('WS volume event refetches the slice (output volume changed)', () async {
    server.store.firstWhere((s) => s['id'] == 'a')['volume'] = 11;
    channels.single.serverSend('{"notify":["volume"]}');
    await pump();

    expect(outputs.outputs.firstWhere((o) => o.id == 'a').volume, 11);
  });

  test('actions while disconnected are no-ops (no requests)', () async {
    conn.disconnect();
    final before = adapter.requests.length;
    expect(await outputs.toggle('b'), isFalse);
    expect(await outputs.setOutputVolume('a', 1), isFalse);
    expect(adapter.requests.length, before);
  });
}
