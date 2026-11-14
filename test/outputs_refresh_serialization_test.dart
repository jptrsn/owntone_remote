import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _configJson = {'websocket_port': 3688, 'version': '29.3'};
const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

Future<void> pump([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Map<String, dynamic> _output({
  required String id,
  required bool selected,
  int volume = 50,
}) => {
  'id': id,
  'name': id.toUpperCase(),
  'type': 'AirPlay 1',
  'selected': selected,
  'has_password': false,
  'needs_auth_key': false,
  'volume': volume,
};

// Unit 012 (unit-011's unguarded-`_refresh` candidate, Outputs side):
// R-09 "outputs list reflects the server" + R-02 (D2 event → refetch)
// require per-event `GET /api/outputs` refreshes to be serialized — one
// in flight, coalesced trailing refetch, and a superseded response can
// never overwrite the newer list. Plain `test`s → real event loop.
void main() {
  group('R-09 refresh serialization (unit 012)', () {
    late ScriptedAdapter adapter;
    late List<FakeWsChannel> channels;
    late ConnectionController conn;
    late OutputsController outputs;

    // The store the server answers from; mutated mid-test to represent
    // an external selection change. Snapshots are taken at REQUEST time.
    late List<Map<String, dynamic>> store;
    var inFlight = 0;
    var maxInFlight = 0;
    var arrivals = 0;
    var holdFirst = false;
    var holdArrival = 0;
    var releaseA = false;

    Future<Response<dynamic>> respond(RequestOptions o) async {
      if (o.method == 'GET' && o.path == '/api/config') {
        return jsonResponse(o, _configJson);
      }
      if (o.method == 'GET' && o.path == '/api/outputs') {
        inFlight++;
        arrivals++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        final snap = List<Map<String, dynamic>>.from(
          store.map((e) => Map<String, dynamic>.from(e)),
        ); // request-time snapshot
        if (holdFirst && arrivals == holdArrival) {
          final deadline = DateTime.now().add(const Duration(seconds: 2));
          while (!releaseA && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }
        inFlight--;
        return jsonResponse(o, {'outputs': snap});
      }
      return jsonResponse(o, <String, dynamic>{});
    }

    setUp(() async {
      store = [
        _output(id: 'a', selected: true),
        _output(id: 'b', selected: false),
        _output(id: 'c', selected: false),
      ];
      inFlight = 0;
      maxInFlight = 0;
      arrivals = 0;
      holdFirst = false;
      releaseA = false;
      adapter = ScriptedAdapter(responder: respond);
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
      releaseA = true;
      outputs.dispose();
      conn.dispose();
    });

    bool bSelected() => outputs.outputs.firstWhere((o) => o.id == 'b').selected;

    test('a superseded outputs fetch answering late must not clobber the '
        'newer list (stale-write race)', () async {
      holdArrival = arrivals + 1;
      holdFirst = true;
      releaseA = false;
      // Event → fetch A starts (holds) with the store as-is (b: false).
      channels.single.serverSend('{"notify":["outputs"]}');
      await pump(20);
      // External selection change while A is in flight; a second event
      // arrives on the same flight → after A lands the trailing fetch
      // must bring the new selection.
      store[1]['selected'] = true;
      channels.single.serverSend('{"notify":["outputs"]}');
      await pump(20);
      releaseA = true;
      holdFirst = false;
      await pump(80);
      expect(
        bSelected(),
        isTrue,
        reason:
            'the stale response from the superseded fetch overwrote '
            'the newer list (unit 012: per-event refreshes must be '
            'serialized)',
      );
    });

    test('a burst of outputs events keeps at most one GET in flight and '
        'the mid-burst change still lands (trailing refetch)', () async {
      holdArrival = arrivals + 1;
      holdFirst = true;
      releaseA = false;
      channels.single.serverSend('{"notify":["outputs"]}');
      await pump(20);
      expect(arrivals, greaterThanOrEqualTo(1));
      final burstStart = arrivals;
      store[1]['selected'] = true;
      for (var i = 0; i < 4; i++) {
        channels.single.serverSend('{"notify":["outputs"]}');
        await pump(10);
      }
      expect(
        arrivals,
        burstStart,
        reason:
            'burst events must coalesce, not start new flights while A '
            'is in flight (single-flight, unit 012)',
      );
      releaseA = true;
      holdFirst = false;
      await pump(80);
      expect(
        arrivals,
        burstStart + 1,
        reason:
            'A plus EXACTLY one coalesced trailing refetch (unit 012)',
      );
      expect(
        maxInFlight,
        1,
        reason:
            'single-flight: $maxInFlight concurrent GET /api/outputs '
            'observed (unit 012)',
      );
      expect(
        bSelected(),
        isTrue,
        reason: 'the mid-burst change must be present after settle '
            '(R-09: outputs list reflects the server)',
      );
    });
  });
}
