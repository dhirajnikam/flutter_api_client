// Full-stack integration scenarios for the architecture audit (w5, grace-hopper).
//
// These wire the WHOLE stack — ApiClient + MockAdapter + real interceptors
// stacked together — and prove the documented end-to-end flows actually behave
// under realistic conditions: auth refresh + retry, cache + ETag revalidation,
// dedup under concurrent load, offline enqueue + replay, and cancellation
// propagation. Unit-level coverage lives in the other audit_* files; this file
// is about the interceptors COMPOSING correctly when run together.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

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

  group('Integration: dedup under concurrent load', () {
    test('5 identical concurrent GETs collapse to a single network hit',
        () async {
      var hits = 0;
      final gate = Completer<void>();
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/slow$'), (_) async {
        hits++;
        await gate.future; // hold all followers behind the leader
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _json('{"ok":true}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [DedupInterceptor()],
        ),
      );

      final futures = List.generate(5, (_) => client.get<dynamic>('slow'));
      // Let the leader register before releasing.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      final results = await Future.wait(futures);

      expect(results.every((r) => r.isSuccess), true);
      expect(hits, 1, reason: '4 followers coalesced onto 1 leader');
    }, timeout: const Timeout(Duration(seconds: 10)));
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
}

Uint8List _json(String s) => Uint8List.fromList(s.codeUnits);
