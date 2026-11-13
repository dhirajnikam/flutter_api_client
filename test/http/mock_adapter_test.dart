import 'dart:convert';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MockAdapter + ApiClient', () {
    test('serves canned responses', () async {
      final mock = MockAdapter();
      mock.on(
        'GET',
        RegExp(r'/users/1$'),
        statusCode: 200,
        body: {'id': 1, 'name': 'A'},
      );
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final res = await client.get<Map<String, dynamic>>('users/1');
      expect(res.isSuccess, true);
      expect(res.statusCode, 200);
      expect(res.data, {'id': 1, 'name': 'A'});
    });

    test('query sends a QUERY method with a request body', () async {
      final mock = MockAdapter()
        ..on(
          'QUERY',
          RegExp(r'/posts/search$'),
          statusCode: 200,
          body: [
            {'id': 1}
          ],
        );
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final res = await client.query<List<dynamic>>(
        'posts/search',
        {'filter': 'ada'},
      );
      expect(res.isSuccess, true);
      expect(res.statusCode, 200);
      expect(res.data, [
        {'id': 1}
      ]);
      expect(mock.received, hasLength(1));
      expect(mock.received.first.method, 'QUERY');
      final sent =
          jsonDecode(utf8.decode(mock.received.first.body as List<int>))
              as Map<String, dynamic>;
      expect(sent, {'filter': 'ada'});
    });
  });

  // =========================================================================
  // MOCK ADAPTER EDGE CASES (it backs nearly every test; its own
  // failure modes matter).
  // =========================================================================
  group('MockAdapter fallbacks', () {
    test('an unmatched route returns a typed 404, never throws', () async {
      final adapter = MockAdapter();
      final api = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: adapter));
      final res = await api.get<dynamic>('nowhere');
      expect(res.isFailure, true);
      expect((res.error as HttpError).statusCode, 404);
    });

    test('captures requests for assertion and matches by method + path',
        () async {
      final adapter = MockAdapter()
        ..on('GET', '/ping', statusCode: 200, body: {'ok': true});
      final api = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: adapter));
      final res = await api.get<dynamic>('ping');
      expect(res.isSuccess, true);
      expect(adapter.received, hasLength(1));
      expect(adapter.received.single.method, 'GET');
    });
  });
}
