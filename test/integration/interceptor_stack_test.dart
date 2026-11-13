// Whole-stack scenarios: ApiClient + MockAdapter + several real interceptors
// composed together.

import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _json(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('Integration: auth refresh + retry', () {
    test('401 triggers a single refresh, retry carries the new token',
        () async {
      final storage = MemoryTokenStorage(accessToken: 'old');
      var refreshes = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        final auth = req.headers['Authorization'];
        if (auth == 'Bearer new') {
          return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _json('{"id":1}'),
          );
        }
        return AdapterResponse(
          statusCode: 401,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _json('{"error":"expired"}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          tokenStorage: storage,
          refreshToken: () async {
            refreshes++;
            await storage.setAccessToken('new');
            return true;
          },
        ),
      );

      final res = await client.get<Map<String, dynamic>>('me');
      expect(res.isSuccess, true, reason: 'refresh+retry should recover');
      expect(res.data, {'id': 1});
      expect(refreshes, 1, reason: 'exactly one refresh');
      expect(mock.received.length, 2, reason: 'one 401, one retry');
      // The first attempt used the old token, the retry the new one — and no
      // internal control header ever reached the adapter.
      expect(mock.received.first.headers['Authorization'], 'Bearer old');
      expect(mock.received.last.headers['Authorization'], 'Bearer new');
      for (final r in mock.received) {
        expect(
          r.headers.keys.where((k) => k.toLowerCase().startsWith('x-fac-')),
          isEmpty,
          reason: 'control headers stripped before transport',
        );
      }
    });
  });

  group('Integration: full interceptor stack composes', () {
    test('auth+cache+dedup+retry+logger together: cached 2nd read, 1 hit',
        () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/config$'), (_) async {
        hits++;
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _json('{"v":$hits}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          tokenStorage: MemoryTokenStorage(accessToken: 't'),
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
            CacheInterceptor(
              store: MemoryCacheStore(),
              // cacheFirst: a fresh cached entry is served without touching the
              // network. (networkFirst would always hit the wire and only fall
              // back to cache on error — a different, also-correct contract.)
              defaultPolicy: CachePolicy.cacheFirst(),
            ),
            DedupInterceptor(),
            PrettyLogger(printer: (_) {}),
          ],
        ),
      );

      final first = await client.get<Map<String, dynamic>>('config');
      final second = await client.get<Map<String, dynamic>>('config');
      expect(first.isSuccess, true);
      expect(second.isSuccess, true);
      expect(hits, 1, reason: 'second read served from cache, no extra hit');
      expect(second.data, first.data, reason: 'cache returns the stored body');
    });
  });

  group('Integration: cache + ETag revalidation', () {
    test('304 Not Modified serves the cached body and keeps it fresh',
        () async {
      var hits = 0;
      const etag = 'W/"v1"';
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/doc$'), (req) async {
        hits++;
        if (req.headers['If-None-Match'] == etag) {
          return AdapterResponse(
            statusCode: 304,
            headers: const {'etag': etag},
            bodyBytes: _json(''),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json', 'etag': etag},
          bodyBytes: _json('{"doc":"hello"}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: const CachePolicy(
                mode: CacheMode.networkFirst,
                ttl: Duration.zero, // force revalidation on the 2nd call
                // useEtag defaults to true — revalidation uses If-None-Match.
              ),
            ),
          ],
        ),
      );

      final first = await client.get<Map<String, dynamic>>('doc');
      final second = await client.get<Map<String, dynamic>>('doc');
      expect(first.data, {'doc': 'hello'});
      expect(hits, 2, reason: 'second call revalidates over the network');
      expect(second.isSuccess, true);
      expect(second.data, {'doc': 'hello'},
          reason: '304 must resolve to the cached body, not an empty one');
    });
  });

  group('Integration: offline enqueue then replay', () {
    test('POST offline is queued, then replayed to success when online',
        () async {
      final store = InMemoryOfflineQueueStore();
      var online = false;
      var serverAccepted = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/orders$'), (_) async {
        if (!online) throw const NetworkError('offline');
        serverAccepted++;
        return AdapterResponse(
          statusCode: 201,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _json('{"id":99}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(store: store, isOnline: () async => online),
          ],
        ),
      );

      // Offline: the write fails for the caller but is captured for replay.
      final offlineRes = await client.post<dynamic>('orders', {'item': 'x'});
      expect(offlineRes.isSuccess, false);
      expect(await store.length, 1, reason: 'mutation queued while offline');

      // Back online: replay drains and re-issues through the client.
      online = true;
      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();
      expect(report.succeeded, 1);
      expect(report.deadLettered, 0);
      expect(serverAccepted, 1, reason: 'queued write reached the server');
      expect(await store.length, 0, reason: 'queue drained after success');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('Integration: cancellation propagates through the stack', () {
    test('a cancelled token surfaces as a typed CancelError Failure', () async {
      final token = CancelToken();
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/big$'), (req) async {
        // An adapter that honours cancellation throws when the token is tripped.
        req.cancelToken?.throwIfCancelled();
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _json('{}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      token.cancel('user navigated away');
      final res = await client.get<dynamic>(
        'big',
        options: RequestOptions(cancelToken: token),
      );
      expect(res.isSuccess, false);
      expect(res.error, isA<CancelError>(),
          reason:
              'cancellation must map to the sealed CancelError, not Unknown');
    });
  });

  group('Integration: built-in interceptors compose through ApiClient', () {
    test(
        'auth + cache + dedup + retry compose: refresh-then-retry, '
        'then a second identical GET is a pure cache hit', () async {
      // A 401 triggers a single refresh + retry, the retried 200 is cached, and
      // a later identical request never touches the network again.
      var networkHits = 0;
      var refreshes = 0;
      final tokens = MemoryTokenStorage(accessToken: 'OLD');

      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        networkHits++;
        final auth = req.headers['Authorization'];
        if (auth == 'Bearer OLD') {
          return AdapterResponse(
            statusCode: 401,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json', 'etag': 'v1'},
          bodyBytes: _json('{"name":"ada"}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          tokenStorage: tokens,
          refreshToken: () async {
            refreshes++;
            await tokens.setAccessToken('NEW');
            return true;
          },
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              // Default ttl is 5 minutes — ample for a same-test second read.
              defaultPolicy: CachePolicy.cacheFirst(),
            ),
            DedupInterceptor(),
            RetryInterceptor(
              policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1),
              ),
            ),
          ],
        ),
      );

      final first = await client.get<Map<String, dynamic>>('me');
      expect(first, isA<Success<Map<String, dynamic>>>());
      expect(first.data, {'name': 'ada'});
      expect(refreshes, 1, reason: 'exactly one refresh on the 401');
      expect(networkHits, 2,
          reason: 'one 401 + one retried 200, no extra hits');

      // Second identical GET: cacheFirst + fresh entry => pure cache hit.
      final second = await client.get<Map<String, dynamic>>('me');
      expect(second, isA<Success<Map<String, dynamic>>>());
      expect(networkHits, 2, reason: 'cache hit must not touch the network');
    });

    // The composition order of Dedup vs Retry changes coalescing efficiency
    // but never correctness:
    //
    //   reversed-onResponse order is the REVERSE of the interceptor list.
    //
    //   [Dedup, Retry]  (Dedup outermost): onResponse fires Retry FIRST. On a
    //     retryable 503 Retry restarts the chain BEFORE Dedup.onResponse runs,
    //     so the leader's completer is still pending. The follower keeps
    //     waiting and rides the leader's eventual 200. => 1 leader, 1 retry,
    //     followers coalesced. Network hits = 2. This is the recommended order.
    //
    //   [Retry, Dedup]  (Retry outermost): onResponse fires Dedup FIRST. Dedup
    //     completes the leader's completer with the *pre-retry* 503 and releases
    //     the follower. Retry then restarts the leader (hit #2 -> 200). But the
    //     already-released follower, seeing a retryable 503 on its OWN way up,
    //     restarts independently (hit #3 -> 200). Correct result for everyone,
    //     but coalescing is defeated for the retried attempt.
    //
    // Both orderings: every caller gets a correct 200, no deadlock, no hang.
    test(
        'Dedup outermost coalesces a retried 503 (2 hits); Retry outermost is '
        'still correct', () async {
      Future<int> hitsFor(List<Interceptor> chain) async {
        var hits = 0;
        final mock = MockAdapter();
        mock.onRequest('GET', RegExp(r'/o$'), (_) async {
          hits++;
          if (hits == 1) {
            return AdapterResponse(
                statusCode: 503, headers: const {}, bodyBytes: _json('busy'));
          }
          return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _json('"o"'),
          );
        });
        final client = ApiClient(
          ApiClientConfig.test(
            baseUrl: 'https://api.example.com',
            adapter: mock,
            interceptors: chain,
          ),
        );
        final results = await Future.wait([
          client.get<dynamic>('o'),
          client.get<dynamic>('o'),
        ]).timeout(
          const Duration(seconds: 4),
          onTimeout: () => throw StateError('ordering deadlocked'),
        );
        // Correctness invariant holds for BOTH orderings: everyone gets 200.
        for (final r in results) {
          expect(r.statusCode, 200, reason: 'every caller must see success');
        }
        return hits;
      }

      RetryInterceptor retry() => RetryInterceptor(
            policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1)),
          );
      DedupInterceptor dedup() =>
          DedupInterceptor(waitTimeout: const Duration(seconds: 5));

      // Recommended order — dedup spans the retry, so followers coalesce.
      expect(await hitsFor([dedup(), retry()]), 2,
          reason: 'Dedup outermost: leader retries, follower coalesces');
      // Inverted order — still correct (asserted inside hitsFor). Whether the
      // retry is coalesced here is an efficiency detail, not a contract.
      expect(await hitsFor([retry(), dedup()]), inInclusiveRange(2, 3));
    });

    test(
        'offline + retry compose: a mutating POST that fails the network while '
        'offline is enqueued exactly once (retry does not double-enqueue)',
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
            // Retry must NOT retry a POST (not a safe method), so offline gets
            // exactly one shot at enqueuing. Ordering: retry above offline.
            RetryInterceptor(
              policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1),
              ),
            ),
            OfflineQueueInterceptor(store: store, isOnline: () async => false),
          ],
        ),
      );

      final res = await client.post<dynamic>('save', {'n': 1});
      expect(res, isA<Failure<dynamic>>());
      final drained = await store.drain();
      expect(drained, hasLength(1),
          reason: 'POST is unsafe -> not retried -> enqueued exactly once');
    });
  });
}
