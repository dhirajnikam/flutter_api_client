import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Default headers & locale', () {
    test('defaults are unchanged (Accept, Accept-Language: en, Content-Type)',
        () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.post<dynamic>('x', {'a': 1});
      final h = mock.received.single.headers;
      expect(h['Accept'], 'application/json');
      expect(h['Accept-Language'], 'en');
      expect(h['Content-Type'], 'application/json');
    });

    test('custom locale + accept + content-type are applied', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          defaultAccept: 'application/vnd.api+json',
          defaultAcceptLanguage: 'fr-CA',
          defaultContentType: 'application/json; charset=utf-8',
        ),
      );
      await client.post<dynamic>('x', {'a': 1});
      final h = mock.received.single.headers;
      expect(h['Accept'], 'application/vnd.api+json');
      expect(h['Accept-Language'], 'fr-CA');
      expect(h['Content-Type'], 'application/json; charset=utf-8');
    });

    test('defaultHeaders replaces the built-in block entirely', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          defaultHeaders: const {'Accept': 'text/plain', 'X-App': 'demo'},
        ),
      );
      await client.get<dynamic>('x');
      final h = mock.received.single.headers;
      expect(h['Accept'], 'text/plain');
      expect(h['X-App'], 'demo');
      expect(h.containsKey('Accept-Language'), false);
    });

    test('per-request headers still override defaults (case-insensitive)',
        () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.get<dynamic>('x',
          options: const RequestOptions(headers: {'accept': 'text/csv'}));
      final h = mock.received.single.headers;
      final acceptKeys =
          h.keys.where((k) => k.toLowerCase() == 'accept').toList();
      expect(acceptKeys.length, 1);
      expect(h[acceptKeys.single], 'text/csv');
    });
  });

  group('Success status predicate', () {
    test('default treats 2xx as success, others as failure', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 201, body: {'ok': true})
        ..on('GET', RegExp(r'/moved$'), statusCode: 302, body: {'ok': false});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final res = await client.get<Map<String, dynamic>>('x');
      expect(res.isSuccess, true);
      final moved = await client.get<Map<String, dynamic>>('moved');
      expect(moved.isFailure, true);
      expect(moved.statusCode, 302);
    });

    test('custom predicate can treat 3xx as success', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 302, body: {'redirect': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          isSuccessStatus: (c) => c >= 200 && c < 400,
        ),
      );
      final res = await client.get<Map<String, dynamic>>('x');
      expect(res.isSuccess, true);
      expect(res.data, {'redirect': true});
    });

    test('custom predicate can treat a 2xx as failure', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 204, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          isSuccessStatus: (c) => c == 200,
        ),
      );
      final res = await client.get<dynamic>('x');
      expect(res.isSuccess, false);
      expect(res.statusCode, 204);
    });
  });
}
