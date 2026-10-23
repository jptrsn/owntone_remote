import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'fakes/fake_owntone_server.dart';

/// The 10-output live shape (docs/API.md, verified 2026-10-22): string ids
/// of wildly different lengths, `AirPlay 1` type, per-output volume +
/// format fields the app must parse without breaking on unknowns.
const _liveOutputs = {
  'outputs': [
    {
      'id': '1814023484',
      'name': 'Bathroom display',
      'type': 'Chromecast',
      'selected': false,
      'has_password': false,
      'requires_auth': false,
      'needs_auth_key': false,
      'volume': 50,
      'offset_ms': 0,
      'format': 'opus',
      'supported_formats': ['opus'],
    },
    {
      'id': '207183922776680',
      'name': 'Volumio Kitchen',
      'type': 'AirPlay 1',
      'selected': true,
      'has_password': false,
      'requires_auth': false,
      'needs_auth_key': false,
      'volume': 36,
      'offset_ms': 0,
      'format': 'alac',
      'supported_formats': ['alac'],
    },
    {
      'id': '0',
      'name': 'Server',
      'type': 'ALSA',
      'selected': false,
      'has_password': false,
      'requires_auth': false,
      'needs_auth_key': false,
      'volume': 8,
      'offset_ms': 0,
      'format': 'pcm',
      'supported_formats': ['pcm'],
    },
    {
      'id': 'x',
      'name': 'Mystery',
      'type': 'Pulseaudio 12',
      'selected': false,
      'has_password': false,
      'requires_auth': false,
      'needs_auth_key': false,
      'volume': 5,
    },
  ],
};

/// R-09 wire format: `getOutputs` parses the live shape (incl. unknown
/// type strings, display-only); `setOutputs` posts the full id list as the
/// JSON body of one `PUT /api/outputs/set`; `setOutput` posts selected /
/// pin / volume on the single-output endpoint; `setOutputVolume` puts
/// `output_id` on the player-volume endpoint.
void main() {
  late ScriptedAdapter adapter;
  late OwntoneApi api;
  final seen = <RequestOptions>[];

  setUp(() {
    adapter = ScriptedAdapter(
      responder: (o) {
        seen.add(o);
        switch (o.path) {
          case '/api/outputs':
            return jsonResponse(o, _liveOutputs);
          default:
            return Response(requestOptions: o, statusCode: 204);
        }
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    api = OwntoneApi(dio: dio, baseUrl: Uri.parse('http://10.0.0.5:3689'));
    seen.clear();
  });

  test(
    'getOutputs parses all fields; unknown types stay plain strings',
    () async {
      final outputs = await api.getOutputs();
      expect(outputs, hasLength(4));
      final kitchen = outputs.firstWhere((o) => o.id == '207183922776680');
      expect(kitchen.name, 'Volumio Kitchen');
      expect(kitchen.type, 'AirPlay 1');
      expect(kitchen.selected, isTrue);
      expect(kitchen.volume, 36);
      expect(kitchen.hasPassword, isFalse);
      expect(kitchen.needsAuthKey, isFalse);
      final mystery = outputs.firstWhere((o) => o.id == 'x');
      expect(mystery.type, 'Pulseaudio 12', reason: 'display-only, unparsed');
    },
  );

  test(
    'setOutputs: one PUT /api/outputs/set, JSON body = full id list',
    () async {
      await api.setOutputs(['207183922776680', '0']);
      expect(seen.map((o) => '${o.method} ${o.path}'), [
        'PUT /api/outputs/set',
      ]);
      final body = seen.single.data as Map<String, dynamic>;
      expect(body, {
        'outputs': ['207183922776680', '0'],
      }, reason: 'enables exactly this set, disables the rest');
    },
  );

  test('setOutputs with the empty set sends an empty list', () async {
    await api.setOutputs(const []);
    expect(seen.single.data, {
      'outputs': <String>[],
    }, reason: 'disables all outputs (empty-set behaviour)');
  });

  test('setOutput: pin flow body is selected + pin (R-09)', () async {
    await api.setOutput('207183922776680', selected: true, pin: 's3cret');
    expect(seen.single.path, '/api/outputs/207183922776680');
    expect(seen.single.data, {'selected': true, 'pin': 's3cret'});
  });

  test('setOutput: volume-only body carries no selected/pin keys', () async {
    await api.setOutput('1814023484', volume: 42);
    expect(seen.single.data, {'volume': 42});
  });

  test(
    'setOutputVolume: output_id rides on the player-volume endpoint',
    () async {
      await api.setOutputVolume('1814023484', 42);
      expect(adapter.requests, [
        'PUT /api/player/volume?volume=42&output_id=1814023484',
      ]);
    },
  );
}
