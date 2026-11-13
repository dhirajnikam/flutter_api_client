import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

CacheEntry _entry(String key) => CacheEntry(
      key: key,
      statusCode: 200,
      headers: const {},
      bodyBytes: Uint8List.fromList('{}'.codeUnits),
      savedAt: DateTime(2024),
    );

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

Future<Box<String>> _openBox(String suffix) async {
  final dir = await Directory.systemTemp.createTemp('cache_store_$suffix');
  Hive.init(dir.path);
  final box = await Hive.openBox<String>('cache_store_$suffix');
  addTearDown(() async {
    if (box.isOpen) await box.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return box;
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
    // savedAt is not in the past, so zero elapsed time cannot be what makes
    // these stale: only the non-positive-TTL rule can, whatever the clock
    // resolution.
    CacheEntry notYetAged() => CacheEntry(
          key: 'k',
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List(0),
          savedAt: DateTime.now().add(const Duration(hours: 1)),
        );

    test('a zero TTL is never fresh, even with no time elapsed', () {
      expect(notYetAged().isFresh(Duration.zero), isFalse);
    });

    test('a negative TTL is never fresh', () {
      expect(notYetAged().isFresh(const Duration(seconds: -1)), isFalse);
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
      await write('c');

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

  group('HiveCacheStore', () {
    test('round-trips a CacheEntry including body bytes and etag', () async {
      final store = HiveCacheStore(await _openBox('roundtrip'));
      final entry = CacheEntry(
        key: 'GET https://api.example.com/users',
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyBytes: _b('{"users":[1,2]}'),
        savedAt: DateTime(2024, 6, 1, 12),
        etag: '"v7"',
      );

      await store.write(entry);
      final back = await store.read(entry.key);

      expect(back, isNotNull);
      expect(back!.statusCode, 200);
      expect(back.headers['content-type'], 'application/json');
      expect(utf8.decode(back.bodyBytes), '{"users":[1,2]}');
      expect(back.savedAt, DateTime(2024, 6, 1, 12));
      expect(back.etag, '"v7"');
    });

    test('a corrupt record reads as a miss and is deleted', () async {
      final box = await _openBox('corrupt');
      final store = HiveCacheStore(box);
      await store.write(CacheEntry(
        key: 'k',
        statusCode: 200,
        headers: const {},
        bodyBytes: _b('x'),
        savedAt: DateTime(2025),
      ));
      await box.put(box.keys.single, 'not json at all {');

      expect(await store.read('k'), isNull);
      expect(box.isEmpty, isTrue,
          reason: 'corruption must not shadow future writes');
    });

    test('stores an entry whose key is longer than Hive allows', () async {
      final store = HiveCacheStore(await _openBox('long_key'));
      final key = 'GET https://api.example.com/x\nx-long:${'a' * 400}';
      await store.write(CacheEntry(
        key: key,
        statusCode: 200,
        headers: const {},
        bodyBytes: _b('body'),
        savedAt: DateTime(2025),
      ));

      expect((await store.read(key))?.bodyBytes, _b('body'));
      expect(await store.keys(), [key]);
      await store.delete(key);
      expect(await store.read(key), isNull);
    });

    test('maxEntries evicts the oldest savedAt first', () async {
      final store = HiveCacheStore(await _openBox('evict'), maxEntries: 2);
      CacheEntry entry(String key, DateTime savedAt) => CacheEntry(
            key: key,
            statusCode: 200,
            headers: const {},
            bodyBytes: _b('x'),
            savedAt: savedAt,
          );

      await store.write(entry('old', DateTime(2024)));
      await store.write(entry('mid', DateTime(2024, 6)));
      await store.write(entry('new', DateTime(2025)));

      expect(await store.read('old'), isNull, reason: 'oldest evicted');
      expect(await store.read('mid'), isNotNull);
      expect(await store.read('new'), isNotNull);
    });

    test('serves offline reads through CacheInterceptor across store handoff',
        () async {
      final store = HiveCacheStore(await _openBox('offline_reads'));
      final mock = MockAdapter();
      var networkCalls = 0;
      mock.onRequest('GET', RegExp(r'/profile$'), (_) async {
        networkCalls++;
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _b('{"name":"dhiraj"}'),
        );
      });

      ApiClient buildClient() => ApiClient(ApiClientConfig.test(
            baseUrl: 'https://api.example.com',
            adapter: mock,
            interceptors: [
              CacheInterceptor(
                store: store,
                defaultPolicy:
                    CachePolicy.cacheFirst(ttl: const Duration(hours: 1)),
              ),
            ],
          ));

      final warm = await buildClient().get<dynamic>('profile');
      expect(warm.isSuccess, true);
      expect(networkCalls, 1);

      // A fresh client (simulating an app restart) reuses the persisted
      // entry without touching the network.
      final restarted = await buildClient().get<dynamic>('profile');
      expect(restarted.isSuccess, true);
      expect(restarted.data, {'name': 'dhiraj'});
      expect(networkCalls, 1, reason: 'served from the persistent cache');
    });
  });

  group('MemoryCacheStore — byte bound', () {
    CacheEntry entry(String key, int bytes) => CacheEntry(
          key: key,
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List(bytes),
          savedAt: DateTime.now(),
        );

    test('evicts the LRU entry when total bytes exceed maxBytes', () async {
      final store = MemoryCacheStore(maxEntries: 100, maxBytes: 100);
      await store.write(entry('a', 60));
      await store.write(entry('b', 60)); // 120 > 100 -> evict 'a'
      expect(await store.read('a'), isNull);
      expect(await store.read('b'), isNotNull);
    });

    test('keeps a single oversized entry rather than emptying the cache',
        () async {
      final store = MemoryCacheStore(maxBytes: 10);
      await store.write(entry('big', 1000));
      expect(await store.read('big'), isNotNull);
    });
  });
}
