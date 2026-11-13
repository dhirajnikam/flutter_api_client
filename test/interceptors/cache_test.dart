import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

InterceptedRequest _req({
  String method = 'GET',
  String endpoint = '/x',
  Map<String, String>? headers,
  Object? data,
}) =>
    InterceptedRequest(
      method: method,
      endpoint: endpoint,
      headers: headers ?? <String, String>{},
      options: const RequestOptions(),
      data: data,
    );

/// Test cache store that exposes its single entry so tests can inspect /
/// backdate `savedAt` without guessing the interceptor's internal key.
class _RecordingCacheStore implements CacheStore {
  final Map<String, CacheEntry> _m = {};

  CacheEntry get only => _m.values.single;
  void replaceOnly(CacheEntry e) {
    final key = _m.keys.single;
    _m[key] = e;
  }

  @override
  Future<CacheEntry?> read(String key) async => _m[key];
  @override
  Future<void> write(CacheEntry entry) async => _m[entry.key] = entry;
  @override
  Future<void> delete(String key) async => _m.remove(key);
  @override
  Future<void> clear() async => _m.clear();
}

/// Seeds the store with a fresh 200 entry through the interceptor (so the key
/// is whatever the interceptor computes), via [CacheInterceptor.onResponse].
Future<void> _seed(
  CacheInterceptor interceptor,
  _RecordingCacheStore store,
  InterceptedRequest req, {
  required String body,
  String? etag,
}) async {
  await interceptor.onResponse(
    req,
    AdapterResponse(
      statusCode: 200,
      headers: {if (etag != null) 'etag': etag},
      bodyBytes: _b(body),
    ),
  );
}

/// Like [_seed] but then backdates `savedAt` so the entry is stale.
Future<void> _seedThenStale(
  CacheInterceptor interceptor,
  _RecordingCacheStore store,
  InterceptedRequest req, {
  required String body,
  String? etag,
}) async {
  await _seed(interceptor, store, req, body: body, etag: etag);
  final e = store.only;
  store.replaceOnly(CacheEntry(
    key: e.key,
    statusCode: e.statusCode,
    headers: e.headers,
    bodyBytes: e.bodyBytes,
    savedAt: DateTime.now().subtract(const Duration(hours: 1)),
    etag: e.etag,
  ));
}

/// Cache store wrapper that counts writes.
class _CountingCacheStore implements CacheStore {
  final MemoryCacheStore _inner = MemoryCacheStore();
  int writes = 0;

  @override
  Future<CacheEntry?> read(String key) => _inner.read(key);

  @override
  Future<void> write(CacheEntry entry) async {
    writes++;
    await _inner.write(entry);
  }

  @override
  Future<void> delete(String key) => _inner.delete(key);

  @override
  Future<void> clear() => _inner.clear();
}

void main() {
  group('CacheInterceptor — networkFirst', () {
    test('always hits network, but caches on first call', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/data$'), (_) async {
        hits++;
        return AdapterResponse(
            statusCode: 200, headers: const {}, bodyBytes: _b('{"n":$hits}'));
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
      expect(hits, 2);
    });
    test('falls back to cached entry on network failure', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/offline$'), (_) async {
        hits++;
        if (hits == 1) {
          return AdapterResponse(
            statusCode: 200,
            headers: const {},
            bodyBytes: _b('{"n":1}'),
          );
        }
        throw const NetworkError('offline');
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

      final first = await client.get<dynamic>('offline');
      final second = await client.get<dynamic>('offline');

      expect(first.isSuccess, true);
      expect(second.isSuccess, true);
      expect(second.headers['x-fac-cache-hit'], 'hit');
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
        return AdapterResponse(
            statusCode: 200, headers: const {}, bodyBytes: _b('{"v":1}'));
      });

      final store = MemoryCacheStore();

      final populateClient = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: store,
              defaultPolicy: CachePolicy.cacheFirst(),
            ),
          ],
        ),
      );
      await populateClient.get<dynamic>('item');
      expect(hits, 1);

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
      expect(hits, 1);
    });
    test('does not reuse cached entry across different authorization headers',
        () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/profile$'), (req) async {
        hits++;
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"auth":"${req.headers['Authorization']}"}'),
        );
      });

      final store = MemoryCacheStore();
      final cacheFirstClient = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: store,
              defaultPolicy: CachePolicy.cacheFirst(),
            ),
          ],
        ),
      );

      final first = await cacheFirstClient.get<Map<String, dynamic>>(
        'profile',
        options: const RequestOptions(
          headers: {'Authorization': 'Bearer user-a'},
        ),
      );
      expect(first.isSuccess, true);
      expect(hits, 1);

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

      final second = await cacheOnlyClient.get<dynamic>(
        'profile',
        options: const RequestOptions(
          headers: {'Authorization': 'Bearer user-b'},
        ),
      );

      expect(second.statusCode, 504);
      expect(hits, 1);
    });
  });

  group('CacheInterceptor — staleWhileRevalidate', () {
    test('serves from cache while TTL is still fresh', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/swr$'), (_) async {
        hits++;
        return AdapterResponse(
            statusCode: 200, headers: const {}, bodyBytes: _b('{"n":$hits}'));
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.staleWhileRevalidate(
                const Duration(minutes: 5),
              ),
            ),
          ],
        ),
      );

      final r1 = await client.get<dynamic>('swr');
      expect(r1.isSuccess, true);
      expect(hits, 1);

      final r2 = await client.get<dynamic>('swr');
      expect(r2.isSuccess, true);
      expect(r2.headers['x-fac-cache-hit'], 'hit');
      expect(hits, 1);
    });
  });

  group('CacheInterceptor — ETag / 304', () {
    test('sends If-None-Match on second request and serves cache on 304',
        () async {
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

      final r2 = await client.get<dynamic>('etag');
      expect(r2.isSuccess, true);
      expect(hits, 2);
      expect(r2.headers['x-fac-cache-hit'], 'hit');
    });
  });

  group('CacheInterceptor — 304 refreshes savedAt', () {
    test('a 304 restarts the freshness window so TTL is honored', () async {
      final store = _RecordingCacheStore();
      final interceptor = CacheInterceptor(
        store: store,
        defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(seconds: 30)),
      );

      await _seedThenStale(
        interceptor,
        store,
        _req(),
        body: 'cached',
        etag: 'v1',
      );

      final req = _req();
      final res304 = AdapterResponse(
        statusCode: 304,
        headers: const {},
        bodyBytes: Uint8List(0),
      );
      final r = await interceptor.onResponse(req, res304);
      expect(r, isA<ResolveResult>());

      // A subsequent cacheFirst request must now be a fresh hit
      // (ResolveResult) instead of revalidating (ProceedResult).
      final next = await interceptor.onRequest(_req());
      expect(next, isA<ResolveResult>(),
          reason: '304 must refresh savedAt so the entry is fresh again');
    });
  });

  group('CacheInterceptor — network fallback beyond networkFirst', () {
    test('staleWhileRevalidate serves cached body on network error', () async {
      final store = _RecordingCacheStore();
      final interceptor = CacheInterceptor(
        store: store,
        defaultPolicy:
            CachePolicy.staleWhileRevalidate(const Duration(seconds: 1)),
      );
      await _seedThenStale(interceptor, store, _req(), body: 'stale');

      final r = await interceptor.onError(_req(), const NetworkError('down'));
      expect(r, isA<ResolveResult>());
      final res = (r as ResolveResult).response;
      expect(utf8.decode(res.bodyBytes), 'stale');
    });

    test('cacheFirst serves cached body on network error', () async {
      final store = _RecordingCacheStore();
      final interceptor = CacheInterceptor(
        store: store,
        defaultPolicy: CachePolicy.cacheFirst(),
      );
      await _seed(interceptor, store, _req(), body: 'lkg');

      final r = await interceptor.onError(_req(), const TimeoutError('slow'));
      expect(r, isA<ResolveResult>());
    });

    test('cacheOnly never lands here; non-transient error passes through',
        () async {
      final store = _RecordingCacheStore();
      final interceptor = CacheInterceptor(
        store: store,
        defaultPolicy: CachePolicy.networkFirst(),
      );
      await _seed(interceptor, store, _req(), body: 'x');
      // An HttpError (server reached) must NOT be masked by the cache.
      final r = await interceptor.onError(
        _req(),
        const HttpError('boom', statusCode: 500),
      );
      expect(r, isA<RejectResult>());
    });
  });

  group('CacheInterceptor — TTL measured from origin fetch', () {
    test('a cache hit does not rewrite the entry (no sliding TTL)', () async {
      final store = _CountingCacheStore();
      final mock = MockAdapter();
      mock.on('GET', RegExp(r'/config$'), statusCode: 200, body: {'v': 1});
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          CacheInterceptor(
            store: store,
            defaultPolicy: CachePolicy.cacheFirst(),
          ),
        ],
      ));

      await client.get<dynamic>('config');
      expect(store.writes, 1);

      final second = await client.get<dynamic>('config');
      expect(second.isSuccess, true);
      expect(mock.received, hasLength(1),
          reason: 'second call must be served from cache');
      expect(store.writes, 1,
          reason: 'a hit must not refresh savedAt (sliding TTL)');
    });

    test('a 304 whose entry was evicted mid-flight re-fetches the full body',
        () async {
      final store = _CountingCacheStore();
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/doc$'), (req) async {
        final conditional =
            req.headers.keys.any((k) => k.toLowerCase() == 'if-none-match');
        if (conditional) {
          // The entry is evicted while the conditional request is in flight.
          await store.clear();
          return AdapterResponse(
            statusCode: 304,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {
            'content-type': 'application/json',
            'etag': '"v1"',
          },
          bodyBytes: _b('{"doc":true}'),
        );
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          CacheInterceptor(
            store: store,
            defaultPolicy: CachePolicy.cacheFirst(ttl: Duration.zero),
          ),
        ],
      ));

      final first = await client.get<dynamic>('doc');
      expect(first.isSuccess, true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final second = await client.get<dynamic>('doc');
      expect(second.isSuccess, true,
          reason: 'a bare 304 with no cache entry must re-fetch, not fail');
      expect(second.statusCode, 200);
      // initial + conditional (304) + unconditional re-fetch
      expect(mock.received, hasLength(3));
      final refetch = mock.received.last;
      expect(
        refetch.headers.keys.any((k) => k.toLowerCase() == 'if-none-match'),
        isFalse,
        reason: 're-fetch must drop the stale validator',
      );
    });

    test('capitalised ETag response header still enables revalidation',
        () async {
      final store = _CountingCacheStore();
      var conditionalSeen = false;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/tagged$'), (req) async {
        final inm = req.headers.entries
            .where((e) => e.key.toLowerCase() == 'if-none-match')
            .map((e) => e.value)
            .firstOrNull;
        if (inm == '"v1"') {
          conditionalSeen = true;
          return AdapterResponse(
            statusCode: 304,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {
            'content-type': 'application/json',
            'ETag': '"v1"',
          },
          bodyBytes: _b('{"tagged":1}'),
        );
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          CacheInterceptor(
            store: store,
            defaultPolicy: CachePolicy.cacheFirst(ttl: Duration.zero),
          ),
        ],
      ));

      await client.get<dynamic>('tagged');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await client.get<dynamic>('tagged');

      expect(conditionalSeen, isTrue,
          reason: 'the ETag stored from a capitalised header must be sent '
              'back as If-None-Match');
      expect(second.isSuccess, true);
      expect(second.statusCode, 200, reason: '304 serves the cached body');
    });

    test('a cacheOnly miss fails fast instead of being retried with backoff',
        () async {
      final mock = MockAdapter();
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          RetryInterceptor(
            policy: RetryPolicy(
              baseDelay: const Duration(seconds: 10),
              useJitter: false,
            ),
          ),
          CacheInterceptor(store: _CountingCacheStore()),
        ],
      ));

      final sw = Stopwatch()..start();
      final result = await client.get<dynamic>(
        'missing',
        options: RequestOptions(cachePolicy: CachePolicy.cacheOnly()),
      );
      sw.stop();

      expect(result.isSuccess, false);
      expect(result.statusCode, 504);
      expect(mock.received, isEmpty, reason: 'cacheOnly never hits network');
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'the synthetic 504 must not go through retry backoff');
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

  test('the cache key separates users without containing the token', () async {
    var hits = 0;
    final mock = MockAdapter()
      ..onRequest('GET', RegExp(r'/me$'), (_) async {
        hits++;
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: Uint8List.fromList(utf8.encode('{"n":$hits}')),
        );
      });
    final storage = MemoryTokenStorage(accessToken: 'secret-token-A');
    final store = MemoryCacheStore();
    final client = ApiClient(ApiClientConfig(
      baseUrl: 'https://api.example.com',
      adapter: mock,
      tokenStorage: storage,
      authHeaderName: 'X-Session',
      interceptors: [
        CacheInterceptor(
          store: store,
          defaultPolicy: CachePolicy.cacheFirst(),
        ),
      ],
    ));

    await client.get<dynamic>('me');
    await client.get<dynamic>('me');
    expect(hits, 1, reason: 'same user is served from the cache');

    await storage.setAccessToken('secret-token-B');
    await client.get<dynamic>('me');
    expect(hits, 2, reason: 'another user never sees the first one\'s entry');

    expect((await store.keys()).join('\n'), isNot(contains('secret-token')));
  });
}
