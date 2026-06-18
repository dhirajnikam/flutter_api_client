import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('RetryPolicy.delayFor — Retry-After', () {
    AdapterResponse resWithRetryAfter(String value) => AdapterResponse(
          statusCode: 503,
          headers: {'retry-after': value},
          bodyBytes: Uint8List(0),
        );

    test('clamps a huge delta-seconds value to maxDelay', () {
      final policy = RetryPolicy(maxDelay: const Duration(seconds: 10));
      expect(
        policy.delayFor(1, resWithRetryAfter('86400')),
        const Duration(seconds: 10),
      );
    });

    test('honours a small delta-seconds value verbatim', () {
      final policy = RetryPolicy(maxDelay: const Duration(seconds: 10));
      expect(
        policy.delayFor(1, resWithRetryAfter('5')),
        const Duration(seconds: 5),
      );
    });

    test('ignores a negative value and falls back to backoff', () {
      final policy = RetryPolicy(
        baseDelay: const Duration(milliseconds: 50),
        useJitter: false,
      );
      // Negative -> parse returns null -> exponential backoff (attempt 1).
      expect(policy.delayFor(1, resWithRetryAfter('-5')),
          const Duration(milliseconds: 50));
    });

    test('parses an HTTP-date and clamps a far-future date to maxDelay', () {
      final policy = RetryPolicy(maxDelay: const Duration(seconds: 10));
      expect(
        policy.delayFor(1, resWithRetryAfter('Wed, 21 Oct 2099 07:28:00 GMT')),
        const Duration(seconds: 10),
      );
    });
  });

  group('RetryPolicy.delayFor — full jitter', () {
    test('stays within [0, capped] across many samples', () {
      final policy = RetryPolicy(baseDelay: const Duration(milliseconds: 100));
      // attempt 3 -> capped = 100ms * 2^2 = 400ms (well under default maxDelay).
      for (var i = 0; i < 500; i++) {
        final ms = policy.delayFor(3, null).inMilliseconds;
        expect(ms, inInclusiveRange(0, 400));
      }
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

    test('count bound still applies', () async {
      final store = MemoryCacheStore(maxEntries: 1);
      await store.write(entry('a', 1));
      await store.write(entry('b', 1));
      expect(await store.read('a'), isNull);
      expect(await store.read('b'), isNotNull);
    });
  });

  group('GraphQL APQ default hash', () {
    test('sends a real SHA-256 hex digest of the document', () async {
      const document = 'query { viewer { id } }';
      String? sentHash;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/graphql$'), (req) async {
        final body = jsonDecode(utf8.decode(req.body as List<int>))
            as Map<String, dynamic>;
        final pq = (body['extensions'] as Map)['persistedQuery'] as Map;
        sentHash = pq['sha256Hash'] as String?;
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: Uint8List.fromList(
            utf8.encode(jsonEncode({
              'data': {
                'viewer': {'id': '1'}
              }
            })),
          ),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final gql = GraphQLClient(client, usePersistedQueries: true);
      await gql.query<dynamic>(document);

      final expected = sha256.convert(utf8.encode(document)).toString();
      expect(sentHash, isNotNull);
      expect(sentHash, hasLength(64));
      expect(sentHash, expected);
    });
  });

  group('DedupInterceptor — retry re-entry', () {
    test('a retried deduped GET does not deadlock', () async {
      var calls = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/retry$'), (req) async {
        calls++;
        if (calls == 1) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List.fromList(utf8.encode('{"ok":true}')),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            DedupInterceptor(),
            RetryInterceptor(
              policy: RetryPolicy(
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
                retryOnStatus: const {503},
              ),
            ),
          ],
        ),
      );

      final res = await client
          .get<dynamic>('retry')
          .timeout(const Duration(seconds: 5));
      expect(res.isSuccess, true);
      expect(calls, 2);
    });
  });

  group('ApiClient.stream', () {
    test('returns the body as a consumable stream (buffered fallback)',
        () async {
      final mock = MockAdapter();
      mock.on('GET', '/download', statusCode: 200, body: 'hello world');
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      final res = await client.stream('download');
      expect(res.isSuccess, true);
      expect(await res.data!.toText(), 'hello world');
    });

    test('DefaultHttpAdapter streams chunks without buffering', () async {
      final adapter = DefaultHttpAdapter(
        client: _ChunkedClient([utf8.encode('foo'), utf8.encode('bar')]),
      );
      expect(adapter, isA<StreamingHttpAdapter>());

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/y'),
          headers: const {},
          timeout: const Duration(seconds: 5),
        ),
      );
      expect(res.bodyStream, isNotNull);
      final collected = <int>[];
      await for (final c in res.bodyStream!) {
        collected.addAll(c);
      }
      expect(utf8.decode(collected), 'foobar');
    });
  });

  group('OfflineQueueReplayer', () {
    QueuedRequest queued(String id, {int attempts = 0}) => QueuedRequest(
          id: id,
          method: 'POST',
          endpoint: 'sync',
          headers: const {},
          body: const {'v': 1},
          createdAt: DateTime.parse('2020-01-01T00:00:00Z'),
          attempts: attempts,
        );

    test('replays queued requests and clears the store on success', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(queued('1'));
      final mock = MockAdapter();
      mock.on('POST', '/sync', statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();
      expect(report.succeeded, 1);
      expect(await store.length, 0);
    });

    test('re-enqueues with an incremented attempt on transient failure',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(queued('1'));
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/sync$'),
          (req) async => throw const NetworkError('offline'));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      final report = await OfflineQueueReplayer(
        store: store,
        client: client,
        maxAttempts: 5,
      ).replay();
      expect(report.reEnqueued, 1);
      final remaining = await store.drain();
      expect(remaining.single.attempts, 1);
    });

    test('dead-letters a request that exhausts maxAttempts', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(queued('1', attempts: 1));
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/sync$'),
          (req) async => throw const NetworkError('offline'));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      final report = await OfflineQueueReplayer(
        store: store,
        client: client,
        maxAttempts: 2,
      ).replay();
      expect(report.deadLettered, 1);
      expect(await store.length, 0);
    });
  });
}

class _ChunkedClient extends http.BaseClient {
  _ChunkedClient(this.chunks);

  final List<List<int>> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks),
      200,
      headers: const {'content-type': 'text/plain'},
    );
  }
}
