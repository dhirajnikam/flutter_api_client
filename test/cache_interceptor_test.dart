import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('CacheInterceptor — networkFirst', () {
    test('always hits network, but caches on first call', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/data$'), (_) async {
        hits++;
        return AdapterResponse(statusCode: 200, headers: const {}, bodyBytes: _b('{"n":$hits}'));
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.networkFirst(),
            ),
          ],
        ),
      );

      final r1 = await client.get<dynamic>('data');
      final r2 = await client.get<dynamic>('data');
      expect(r1.isSuccess, true);
      expect(r2.isSuccess, true);
      // networkFirst always goes to network (2 hits)
      expect(hits, 2);
    });
  });

  group('CacheInterceptor — cacheOnly', () {
    test('returns 504 when cache is empty', () async {
      final mock = MockAdapter();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.cacheOnly(),
            ),
          ],
        ),
      );

      final res = await client.get<dynamic>('missing');
      expect(res.statusCode, 504);
    });

    test('returns cached entry when populated', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/item$'), (_) async {
        hits++;
        return AdapterResponse(statusCode: 200, headers: const {}, bodyBytes: _b('{"v":1}'));
      });

      final store = MemoryCacheStore();

      // Populate cache via cacheFirst client
      final populateClient = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: store,
              defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(minutes: 5)),
            ),
          ],
        ),
      );
      await populateClient.get<dynamic>('item');
      expect(hits, 1);

      // cacheOnly client should serve from cache without hitting network
      final cacheOnlyClient = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: store,
              defaultPolicy: CachePolicy.cacheOnly(),
            ),
          ],
        ),
      );

      final res = await cacheOnlyClient.get<dynamic>('item');
      expect(res.isSuccess, true);
      expect(res.headers['x-fac-cache-hit'], 'hit');
      expect(hits, 1); // no second network call
    });
  });

  group('CacheInterceptor — staleWhileRevalidate', () {
    test('serves from cache while TTL is still fresh', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/swr$'), (_) async {
        hits++;
        return AdapterResponse(statusCode: 200, headers: const {}, bodyBytes: _b('{"n":$hits}'));
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.staleWhileRevalidate(
                const Duration(minutes: 5), // long TTL — entry stays fresh
              ),
            ),
          ],
        ),
      );

      // First call: populates cache
      final r1 = await client.get<dynamic>('swr');
      expect(r1.isSuccess, true);
      expect(hits, 1);

      // Second call: TTL not expired, served from cache immediately
      final r2 = await client.get<dynamic>('swr');
      expect(r2.isSuccess, true);
      expect(r2.headers['x-fac-cache-hit'], 'hit');
      expect(hits, 1); // no second network call
    });

    test('goes to network when cache is missing', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/swr2$'), (_) async {
        hits++;
        return AdapterResponse(statusCode: 200, headers: const {}, bodyBytes: _b('{"n":$hits}'));
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.staleWhileRevalidate(const Duration(minutes: 5)),
            ),
          ],
        ),
      );

      final r1 = await client.get<dynamic>('swr2');
      expect(r1.isSuccess, true);
      expect(hits, 1);
    });
  });

  group('CacheInterceptor — ETag / 304', () {
    test('sends If-None-Match on second request and serves cache on 304', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/etag$'), (req) async {
        hits++;
        if (req.headers['If-None-Match'] == '"abc"') {
          return AdapterResponse(
            statusCode: 304,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {'etag': '"abc"'},
          bodyBytes: _b('{"v":1}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.networkFirst(),
            ),
          ],
        ),
      );

      final r1 = await client.get<dynamic>('etag');
      expect(r1.isSuccess, true);
      expect(hits, 1);

      // Second call: should send If-None-Match, receive 304, and serve from cache
      final r2 = await client.get<dynamic>('etag');
      expect(r2.isSuccess, true);
      expect(hits, 2);
      expect(r2.headers['x-fac-cache-hit'], 'hit');
    });
  });

  group('MemoryCacheStore LRU eviction', () {
    test('evicts oldest entry when maxEntries is exceeded', () async {
      final store = MemoryCacheStore(maxEntries: 2);

      Future<void> write(String key) => store.write(
            CacheEntry(
              key: key,
              statusCode: 200,
              headers: const {},
              bodyBytes: Uint8List(0),
              savedAt: DateTime.now(),
            ),
          );

      await write('a');
      await write('b');
      await write('c'); // should evict 'a'

      expect(await store.read('a'), isNull);
      expect(await store.read('b'), isNotNull);
      expect(await store.read('c'), isNotNull);
    });

    test('clear empties all entries', () async {
      final store = MemoryCacheStore();
      await store.write(
        CacheEntry(
          key: 'k',
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List(0),
          savedAt: DateTime.now(),
        ),
      );
      await store.clear();
      expect(await store.read('k'), isNull);
    });

    test('delete removes specific entry', () async {
      final store = MemoryCacheStore();
      await store.write(
        CacheEntry(
          key: 'del',
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List(0),
          savedAt: DateTime.now(),
        ),
      );
      await store.delete('del');
      expect(await store.read('del'), isNull);
    });
  });
}
