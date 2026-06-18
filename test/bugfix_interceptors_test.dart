// Regression tests for bugs FIXED in w3 (interceptors + auth).
//
// Each group below pins a specific failure mode so it cannot silently
// return. Safety-first: a queued write must never be lost, a cache must
// degrade gracefully, a follower must never hang, and a secret must never
// leak. — margaret-hamilton
import 'dart:async';
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

/// Offline store seeded with a fixed list whose [enqueue] always throws, used
/// to prove the replayer survives a persistence failure mid-loop.
class _ThrowOnEnqueueStore implements OfflineQueueStore {
  _ThrowOnEnqueueStore(this._initial);
  final List<QueuedRequest> _initial;
  int enqueueAttempts = 0;

  @override
  Future<void> enqueue(QueuedRequest request) async {
    enqueueAttempts++;
    throw StateError('persist failed');
  }

  @override
  Future<List<QueuedRequest>> drain() async => List.of(_initial);
  @override
  Future<void> remove(String id) async {}
  @override
  Future<int> get length async => 0;
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

void main() {
  group('OfflineQueueInterceptor — unique ids (collision fix)', () {
    test('two same-microsecond same-endpoint enqueues get distinct ids',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'), (_) async {
        throw const NetworkError('offline');
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(store: store, isOnline: () async => false),
          ],
        ),
      );

      // Fire two identical mutations back-to-back. Before the fix they could
      // collide on `microsecondsSinceEpoch-endpoint.hashCode` and the second
      // would overwrite the first in a keyed store.
      await client.post<dynamic>('save', {'n': 1});
      await client.post<dynamic>('save', {'n': 2});

      final drained = await store.drain();
      expect(drained, hasLength(2), reason: 'no write may be lost');
      final ids = drained.map((e) => e.id).toSet();
      expect(ids, hasLength(2), reason: 'ids must be unique');
    });
  });

  group('QueuedRequest.tryFromJson — robustness', () {
    test('returns null on malformed records instead of throwing', () {
      expect(QueuedRequest.tryFromJson(const {}), isNull);
      expect(
        QueuedRequest.tryFromJson(const {'id': 1, 'method': 'POST'}),
        isNull,
      );
      expect(
        QueuedRequest.tryFromJson(const {
          'id': 'a',
          'method': 'POST',
          'endpoint': '/x',
          'createdAt': 'not-a-date',
        }),
        isNull,
      );
    });

    test('coerces a bad headers map and missing attempts gracefully', () {
      final q = QueuedRequest.tryFromJson(<String, Object?>{
        'id': 'a',
        'method': 'POST',
        'endpoint': '/x',
        'createdAt': DateTime(2024).toIso8601String(),
        'headers': {'ok': 'v', 'bad': 123}, // non-string value dropped
      });
      expect(q, isNotNull);
      expect(q!.headers, {'ok': 'v'});
      expect(q.attempts, 0);
    });

    test('fromJson still throws FormatException for the strict callers', () {
      expect(
        () => QueuedRequest.fromJson(const {'id': 1}),
        throwsA(isA<FormatException>()),
      );
    });

    test('round-trips a valid record', () {
      final q = QueuedRequest(
        id: 'x',
        method: 'PUT',
        endpoint: '/p',
        headers: const {'h': 'v'},
        body: {'k': 'v'},
        createdAt: DateTime(2024, 5, 6),
        attempts: 2,
      );
      final back = QueuedRequest.tryFromJson(q.toJson());
      expect(back, isNotNull);
      expect(back!.id, 'x');
      expect(back.attempts, 2);
      expect(back.body, {'k': 'v'});
    });
  });

  group('OfflineQueueReplayer — crash safety', () {
    test('an enqueue failure during re-enqueue does not abort the loop',
        () async {
      // Two transient failures: both want to be re-enqueued. The store's
      // enqueue throws (e.g. disk full / serialization error). Before the fix
      // the first thrown enqueue aborted replay() and the remaining drained
      // request was silently lost. After the fix the loop survives, counts the
      // failure as dead-lettered, and processes every request.
      final store = _ThrowOnEnqueueStore([
        QueuedRequest(
          id: '1',
          method: 'POST',
          endpoint: '/a',
          headers: const {},
          createdAt: DateTime(2024),
        ),
        QueuedRequest(
          id: '2',
          method: 'POST',
          endpoint: '/b',
          headers: const {},
          createdAt: DateTime(2024, 1, 2),
        ),
      ]);

      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/[ab]$'), (_) async {
        throw const NetworkError('offline'); // transient -> wants re-enqueue
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
        ),
      );

      final replayer = OfflineQueueReplayer(store: store, client: client);
      // Must NOT throw, and must have attempted both requests.
      final report = await replayer.replay();
      expect(report.total, 2);
      expect(report.deadLettered, 2);
      expect(store.enqueueAttempts, 2,
          reason: 'both requests were processed despite enqueue throwing');
    });

    test('a transient failure is re-enqueued with an incremented attempt',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
        id: '1',
        method: 'POST',
        endpoint: '/x',
        headers: const {},
        createdAt: DateTime(2024),
      ));
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/x$'), (_) async {
        throw const NetworkError('offline');
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
        ),
      );
      final report = OfflineQueueReplayer(store: store, client: client);
      final r = await report.replay();
      expect(r.reEnqueued, 1);
      final back = await store.drain();
      expect(back.single.attempts, 1);
    });
  });

  group('CacheInterceptor — 304 refreshes savedAt', () {
    test('a 304 restarts the freshness window so TTL is honored', () async {
      final store = _RecordingCacheStore();
      final interceptor = CacheInterceptor(
        store: store,
        defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(seconds: 30)),
      );

      // Seed through the interceptor itself so the cache key matches exactly,
      // then backdate savedAt to make the entry stale.
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

      // Observable consequence: a subsequent cacheFirst request must now be a
      // *fresh* hit (ResolveResult) instead of revalidating (ProceedResult).
      // Before the fix savedAt stayed stale, so this would proceed to network.
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

  group('DedupInterceptor — streaming follower not left hanging', () {
    test('follower is released immediately when leader is a stream', () async {
      final dedup = DedupInterceptor(waitTimeout: const Duration(seconds: 10));

      // Leader registers itself.
      final leader = _req(endpoint: '/s');
      final lr = await dedup.onRequest(leader);
      expect(lr, isA<ProceedResult>());
      final leaderProceed = (lr as ProceedResult).request;

      // Follower starts awaiting the leader.
      final follower = _req(endpoint: '/s');
      final followerFuture = dedup.onRequest(follower);

      // Leader returns a streaming body — cannot be shared.
      final streamRes = AdapterResponse(
        statusCode: 200,
        headers: const {},
        bodyBytes: Uint8List(0),
        bodyStream: const Stream<List<int>>.empty(),
      );
      await dedup.onResponse(leaderProceed, streamRes);

      // Follower must resolve to ProceedResult promptly, NOT block 10s.
      final followerResult = await followerFuture.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('follower hung'),
      );
      expect(followerResult, isA<ProceedResult>());
    });

    test('follower shares a buffered leader response', () async {
      final dedup = DedupInterceptor();
      final leader = _req(endpoint: '/b');
      final lr = await dedup.onRequest(leader);
      final leaderProceed = (lr as ProceedResult).request;

      final follower = _req(endpoint: '/b');
      final followerFuture = dedup.onRequest(follower);

      final res = AdapterResponse(
        statusCode: 200,
        headers: const {},
        bodyBytes: _b('shared'),
      );
      await dedup.onResponse(leaderProceed, res);

      final fr = await followerFuture;
      expect(fr, isA<ResolveResult>());
      expect(utf8.decode((fr as ResolveResult).response.bodyBytes), 'shared');
    });
  });

  // Dedup + Retry through the REAL chain. The isolated dedup tests above only
  // poke the interceptor directly; they never prove the documented "no deadlock
  // on retry" property when a retry restarts the whole chain (the leader's
  // completer must survive the restart and followers must coalesce onto the
  // eventual success, not hang for waitTimeout). Drive it end-to-end. — linus
  group('DedupInterceptor + RetryInterceptor — no deadlock on retry', () {
    test('coalesced followers ride the leader through a retried 503', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        hits++;
        // Fail the first network hit with a retryable 503, then succeed.
        if (hits == 1) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: _b('busy'),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _b('"ok"'),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            DedupInterceptor(waitTimeout: const Duration(seconds: 5)),
            RetryInterceptor(
              policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1),
              ),
            ),
          ],
        ),
      );

      // Three concurrent identical GETs. One leader does the network work
      // (which retries the 503 once); the two followers must coalesce onto the
      // leader's eventual 200 — never deadlock and never time out.
      final results = await Future.wait([
        client.get<dynamic>('flaky'),
        client.get<dynamic>('flaky'),
        client.get<dynamic>('flaky'),
      ]).timeout(
        const Duration(seconds: 4),
        onTimeout: () => throw StateError('dedup+retry deadlocked'),
      );

      for (final r in results) {
        expect(r.statusCode, 200, reason: 'every caller sees the success');
      }
      // Exactly one leader reached the network; it retried the 503 once.
      // Followers coalesced rather than each issuing their own pair of hits.
      expect(hits, 2, reason: 'one leader, one retry — followers coalesced');
    });
  });

  group('Logger — case-insensitive header redaction', () {
    test('PrettyLogger redacts a mixed-case caller-supplied header', () async {
      final lines = <String>[];
      final logger = PrettyLogger(
        printer: lines.add,
        useColors: false,
        redactHeaders: const {'Authorization', 'X-Secret'}, // mixed case
      );
      await logger.onRequest(_req(
        headers: {'Authorization': 'Bearer abc', 'X-Secret': 'hush'},
      ));
      final out = lines.join('\n');
      expect(out, contains('<redacted>'));
      expect(out, isNot(contains('Bearer abc')));
      expect(out, isNot(contains('hush')));
    });

    test('CurlLogger redacts a mixed-case caller-supplied header', () async {
      final lines = <String>[];
      final logger = CurlLogger(
        printer: lines.add,
        redactHeaders: const {'Authorization'},
      );
      await logger.onRequest(_req(
        headers: {'Authorization': 'Bearer abc'},
      ));
      expect(lines.single, isNot(contains('Bearer abc')));
      expect(lines.single, contains('<redacted>'));
    });
  });

  group('AuthInterceptor — concurrent 401 staleness guard', () {
    test('does not refresh again when token already rotated', () async {
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      var refreshCalls = 0;
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          await storage.setAccessToken('NEWER');
          return true;
        },
      );

      // Simulate a request that went out with OLD, but storage already holds
      // NEW (rotated by a concurrent flow) by the time the 401 comes back.
      final req = _req(headers: {
        'Authorization': 'Bearer OLD',
        'x-fac-auth-token-fp': '${'OLD'.length}:${'OLD'.hashCode}',
      });
      await storage.setAccessToken('NEW'); // rotated under us

      final res = AdapterResponse(
        statusCode: 401,
        headers: const {},
        bodyBytes: Uint8List(0),
      );
      final r = await auth.onResponse(req, res);

      // Must retry (ProceedResult) WITHOUT triggering another refresh.
      expect(r, isA<ProceedResult>());
      expect(refreshCalls, 0, reason: 'no redundant refresh');
      final retry = (r as ProceedResult).request;
      expect(retry.headers['x-fac-retried-auth'], '1');
      // Stale Authorization dropped so onRequest re-attaches the fresh token.
      expect(retry.headers.containsKey('Authorization'), isFalse);
    });

    test('refreshes once when token is still the one we used', () async {
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      var refreshCalls = 0;
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          await storage.setAccessToken('FRESH');
          return true;
        },
      );
      final req = _req(headers: {
        'Authorization': 'Bearer OLD',
        'x-fac-auth-token-fp': '${'OLD'.length}:${'OLD'.hashCode}',
      });
      final res = AdapterResponse(
        statusCode: 401,
        headers: const {},
        bodyBytes: Uint8List(0),
      );
      final r = await auth.onResponse(req, res);
      expect(r, isA<ProceedResult>());
      expect(refreshCalls, 1);
    });
  });
}
