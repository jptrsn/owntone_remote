import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'fakes/fake_owntone_server.dart';

/// R-12 (unit 006): the rating endpoints' wire shape —
/// `GET /api/library/tracks/{id}` (rating on the track) and
/// `PUT /api/library/tracks/{id}?rating=` (204).
void main() {
  late ScriptedAdapter adapter;
  late OwntoneApi api;

  const base = 'http://10.0.0.5:3689';

  setUp(() {
    adapter = ScriptedAdapter(
      responder: (o) {
        if (o.method == 'PUT') {
          return Response(requestOptions: o, statusCode: 204);
        }
        return jsonResponse(o, const {
          'id': 1195,
          'title': 'Skunk',
          'artist': 'Thundersmack',
          'album': 'Brass',
          'album_id': '193995476750353277',
          'track_number': 3,
          'length_ms': 343835,
          'rating': 60,
          'uri': 'library:track:1195',
        });
      },
    );
    api = OwntoneApi(
      dio: Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter,
      baseUrl: Uri.parse('$base/'),
    );
  });

  test(
    'getTrack: id path segment, parses rating from the track object',
    () async {
      final track = await api.getTrack(1195);
      expect(adapter.requests.single, 'GET /api/library/tracks/1195');
      expect(track.id, 1195);
      expect(track.title, 'Skunk');
      expect(track.rating, 60);
    },
  );

  test(
    'setRating: PUT with the rating query parameter, 204 accepted',
    () async {
      await api.setRating(1195, 60);
      expect(adapter.requests.single, 'PUT /api/library/tracks/1195?rating=60');
    },
  );

  test('setRating clamps to the server scale (defensive)', () async {
    await api.setRating(1195, 140);
    expect(adapter.requests.single, 'PUT /api/library/tracks/1195?rating=100');
  });
}
