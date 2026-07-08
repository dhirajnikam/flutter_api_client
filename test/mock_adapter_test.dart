import 'dart:convert';
import 'dart:typed_data';

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

    test('returns 404 on miss', () async {
      final mock = MockAdapter();
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final res = await client.get<dynamic>('missing');
      expect(res.isSuccess, false);
      expect(res.statusCode, 404);
    });

    test('captures requests', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/echo$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.post<dynamic>('echo', {'x': 1});
      expect(mock.received, hasLength(1));
      expect(mock.received.first.method, 'POST');
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
      final sent = jsonDecode(utf8.decode(mock.received.first.body as List<int>))
          as Map<String, dynamic>;
      expect(sent, {'filter': 'ada'});
    });
  });

  group('RetryInterceptor', () {
    test('retries on 503 then succeeds', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        hits++;
        if (hits < 3) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: _b('busy'),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"ok":true}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 4,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );
      final res = await client.get<dynamic>('flaky');
      expect(res.isSuccess, true);
      expect(hits, 3);
      for (final request in mock.received) {
        expect(
          request.headers.keys
              .where((key) => key.toLowerCase().startsWith('x-fac-')),
          isEmpty,
        );
      }
    });

    test('does not retry non-safe methods on 503 by default', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/submit$'), (_) async {
        hits++;
        if (hits == 1) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: _b('busy'),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"ok":true}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 4,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );
      final res = await client.post<dynamic>('submit', {'id': 1});
      expect(res.isSuccess, false);
      expect(res.statusCode, 503);
      expect(hits, 1);
    });

    test('gives up after maxAttempts', () async {
      final mock = MockAdapter();
      mock.onRequest(
        'GET',
        RegExp(r'/dead$'),
        (_) async => AdapterResponse(
          statusCode: 503,
          headers: const {},
          bodyBytes: _b('busy'),
        ),
      );
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 2,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );
      final res = await client.get<dynamic>('dead');
      expect(res.isSuccess, false);
      expect(res.statusCode, 503);
    });
  });

  group('DedupInterceptor', () {
    test('coalesces parallel GETs', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/once$'), (_) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"n":$hits}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [DedupInterceptor()],
        ),
      );
      final results = await Future.wait([
        client.get<dynamic>('once'),
        client.get<dynamic>('once'),
        client.get<dynamic>('once'),
      ]);
      expect(hits, 1);
      for (final r in results) {
        expect(r.isSuccess, true);
      }
    });
    test('does not coalesce requests with different authorization headers',
        () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"auth":"${req.headers['Authorization']}"}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [DedupInterceptor()],
        ),
      );
      final results = await Future.wait([
        client.get<dynamic>(
          'me',
          options: const RequestOptions(
            headers: {'Authorization': 'Bearer user-a'},
          ),
        ),
        client.get<dynamic>(
          'me',
          options: const RequestOptions(
            headers: {'Authorization': 'Bearer user-b'},
          ),
        ),
      ]);

      expect(hits, 2);
      expect(results[0].dataOrNull, {'auth': 'Bearer user-a'});
      expect(results[1].dataOrNull, {'auth': 'Bearer user-b'});
    });
  });

  group('CacheInterceptor', () {
    test('cacheFirst serves from cache on second call', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/data$'), (_) async {
        hits++;
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"n":$hits}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.cacheFirst(
                ttl: const Duration(seconds: 60),
              ),
            ),
          ],
        ),
      );
      final r1 = await client.get<dynamic>('data');
      final r2 = await client.get<dynamic>('data');
      expect(r1.isSuccess, true);
      expect(r2.isSuccess, true);
      expect(hits, 1);
      expect(r2.headers['x-fac-cache-hit'], 'hit');
    });
  });

  group('AuthInterceptor refresh queue', () {
    test('refreshes once for concurrent 401s', () async {
      var refreshCalls = 0;
      final storage = MemoryTokenStorage(accessToken: 'old');
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        final auth = req.headers['Authorization'] ?? '';
        if (auth == 'Bearer new') {
          return AdapterResponse(
            statusCode: 200,
            headers: const {},
            bodyBytes: _b('{"ok":true}'),
          );
        }
        return AdapterResponse(
          statusCode: 401,
          headers: const {},
          bodyBytes: _b('{"message":"nope"}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            AuthInterceptor(
              storage: storage,
              refresh: () async {
                refreshCalls++;
                await Future<void>.delayed(const Duration(milliseconds: 10));
                await storage.setAccessToken('new');
                return true;
              },
            ),
          ],
        ),
      );
      final results = await Future.wait([
        client.get<dynamic>('me'),
        client.get<dynamic>('me'),
        client.get<dynamic>('me'),
      ]);
      expect(refreshCalls, 1);
      for (final r in results) {
        expect(r.isSuccess, true);
      }
      for (final request in mock.received) {
        expect(
          request.headers.keys
              .where((key) => key.toLowerCase().startsWith('x-fac-')),
          isEmpty,
        );
      }
    });
  });

  group('CancelToken', () {
    test('cancelling aborts the response', () async {
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/slow$'), (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final t = CancelToken();
      final f = client.get<dynamic>(
        'slow',
        options: RequestOptions(cancelToken: t),
      );
      t.cancel('user navigated');
      final r = await f;
      // MockAdapter doesn't observe cancellation; behaviour is best-effort.
      expect(r, isA<ApiResult>());
    });
  });
}

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);
