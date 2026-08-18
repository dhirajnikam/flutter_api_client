// Selective cache invalidation (CacheInterceptor.evictWhere / evictEndpoint).
//
// Cache keys are requestIdentityKey values — `METHOD url` plus sorted headers,
// including Authorization — so application code cannot reconstruct one to pass
// to CacheStore.delete. Matching on key text is the usable seam; without it the
// only way to drop one stale list endpoint was clearing the entire store.

import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

CacheEntry _entry(String key) => CacheEntry(
      key: key,
      statusCode: 200,
      headers: const {},
      bodyBytes: Uint8List.fromList('{}'.codeUnits),
      savedAt: DateTime(2024),
    );

/// A custom store written against the 1.6.0 CacheStore surface — no keys()
/// override. It must still compile and run, which is what keeps the new
/// method from being a breaking change for existing implementors.
class _LegacyStore implements CacheStore {
  final Map<String, CacheEntry> entries = {};

  @override
  Future<CacheEntry?> read(String key) async => entries[key];

  @override
  Future<void> write(CacheEntry entry) async => entries[entry.key] = entry;

  @override
  Future<void> delete(String key) async => entries.remove(key);

  @override
  Future<void> clear() async => entries.clear();
}

void main() {
  group('MemoryCacheStore.keys', () {
    test('enumerates written keys and reflects deletes', () async {
      final store = MemoryCacheStore();
      await store.write(_entry('GET https://x.test/todos'));
      await store.write(_entry('GET https://x.test/users'));
      expect((await store.keys()).toSet(),
          {'GET https://x.test/todos', 'GET https://x.test/users'});

      await store.delete('GET https://x.test/todos');
      expect((await store.keys()).toSet(), {'GET https://x.test/users'});
    });
  });

  group('CacheEntry.isFresh boundary', () {
    // Regression: isFresh was `elapsed <= ttl`, so a zero TTL read as FRESH
    // whenever DateTime.now() returned the same instant the entry was written
    // (0 <= 0). That made staleWhileRevalidate(Duration.zero) — the documented
    // fallback-only mode — serve the cache on the request path depending on
    // clock resolution, intermittently rather than never.
    test('a zero TTL is never fresh, even written this instant', () {
      final entry = _entry('k');
      final now = CacheEntry(
        key: 'k',
        statusCode: 200,
        headers: const {},
        bodyBytes: entry.bodyBytes,
        savedAt: DateTime.now(), // same instant the check will read
      );
      expect(now.isFresh(Duration.zero), isFalse);
    });

    test('a negative TTL is never fresh', () {
      expect(_entry('k').isFresh(const Duration(seconds: -1)), isFalse);
    });

    test('a non-zero TTL keeps its inclusive bound', () {
      final fresh = CacheEntry(
        key: 'k',
        statusCode: 200,
        headers: const {},
        bodyBytes: Uint8List(0),
        savedAt: DateTime.now(),
      );
      expect(fresh.isFresh(const Duration(hours: 1)), isTrue);

      final old = CacheEntry(
        key: 'k',
        statusCode: 200,
        headers: const {},
        bodyBytes: Uint8List(0),
        savedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      expect(old.isFresh(const Duration(hours: 1)), isFalse);
    });
  });

  group('CacheInterceptor.evictWhere', () {
    test('drops only matching entries and leaves the rest cached', () async {
      final store = MemoryCacheStore();
      await store.write(_entry('GET https://x.test/todos'));
      await store.write(_entry('GET https://x.test/todos?done=1'));
      await store.write(_entry('GET https://x.test/users'));
      final cache = CacheInterceptor(store: store);

      final removed = await cache.evictWhere((k) => k.contains('/todos'));

      expect(removed, 2);
      expect(await store.read('GET https://x.test/users'), isNotNull,
          reason: 'the whole store must not be cleared');
      expect(await store.read('GET https://x.test/todos'), isNull);
    });

    test('returns 0 and removes nothing when nothing matches', () async {
      final store = MemoryCacheStore();
      await store.write(_entry('GET https://x.test/users'));
      final cache = CacheInterceptor(store: store);

      expect(await cache.evictWhere((k) => k.contains('/nope')), 0);
      expect((await store.keys()), hasLength(1));
    });

    test('a pre-existing custom store still compiles and no-ops safely',
        () async {
      final store = _LegacyStore();
      await store.write(_entry('GET https://x.test/todos'));
      final cache = CacheInterceptor(store: store);

      // Not an EnumerableCacheStore, so selective eviction is a no-op rather
      // than an error — the entry survives and delete/clear still work.
      expect(store, isNot(isA<EnumerableCacheStore>()));
      expect(await cache.evictWhere((k) => true), 0);
      expect(store.entries, hasLength(1));
    });
  });

  group('CacheInterceptor.evictEndpoint', () {
    test('matches the endpoint across base URLs and query strings', () async {
      final store = MemoryCacheStore();
      await store.write(_entry('GET https://a.test/todos'));
      await store.write(_entry('GET https://b.test/todos?page=2'));
      await store.write(_entry('GET https://a.test/users'));
      final cache = CacheInterceptor(store: store);

      expect(await cache.evictEndpoint('/todos'), 2);
      expect((await store.keys()).toSet(), {'GET https://a.test/users'});
    });

    test('a header value cannot trigger an eviction', () async {
      final store = MemoryCacheStore();
      // The endpoint text appears only in a HEADER line, never in the URL.
      await store.write(_entry('GET https://x.test/users\nx-note:/todos'));
      final cache = CacheInterceptor(store: store);

      expect(await cache.evictEndpoint('/todos'), 0,
          reason: 'only the METHOD url line is matched, not header values');
      expect((await store.keys()), hasLength(1));
    });

    test('evicts a real cached response so the next call refetches', () async {
      final store = MemoryCacheStore();
      final adapter = MockAdapter();
      var hits = 0;
      adapter.on('GET', '/todos', statusCode: 200, body: const {'v': 1});
      final cache = CacheInterceptor(
        store: store,
        defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(hours: 1)),
      );
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: adapter,
          interceptors: [cache],
        ),
      );

      await client.get<dynamic>('/todos');
      hits = adapter.received.length;
      expect(hits, 1);

      // Second call is served from cache — no new transport hit.
      await client.get<dynamic>('/todos');
      expect(adapter.received.length, hits);

      // After eviction the same call must reach the network again.
      expect(await cache.evictEndpoint('/todos'), greaterThan(0));
      await client.get<dynamic>('/todos');
      expect(adapter.received.length, hits + 1,
          reason: 'evicted entry must no longer satisfy a cacheFirst read');
    });
  });
}
