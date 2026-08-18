// End-to-end: a full offline -> online cycle driving replay safety and
// selective cache invalidation through the PUBLIC API only.
//
// The unit tests in replay_safety_test.dart / cache_eviction_test.dart pin each
// mechanism in isolation. These drive the whole stack the way an app does —
// interceptors wired into ApiClientConfig, a transport that goes offline and
// comes back, optimistic local state, and a cache that must not serve a stale
// list after the queued write lands.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// A transport with a flippable network, standing in for airplane mode.
/// Records every request that actually reached "the server".
class _FlakyServer implements HttpAdapter {
  bool online = false;

  /// Bodies the server accepted, in order — the duplicate detector.
  final List<String> accepted = [];

  /// Headers seen on each accepted write, to assert internal `x-fac-*`
  /// coordination headers never leave the client.
  final List<Map<String, String>> sentHeaders = [];

  /// Rows the server holds, returned by GET /todos.
  final List<Map<String, Object?>> rows = [];

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    if (!online) {
      throw const NetworkError('airplane mode');
    }
    final path = request.url.path;
    if (request.method == 'GET') {
      // Snapshot: a cached body must stay the list as it was when fetched,
      // not alias a list the test mutates afterwards.
      return _json(200, {'todos': List<Map<String, Object?>>.from(rows)});
    }
    final body = request.body is String
        ? request.body as String
        : jsonEncode(request.body);
    accepted.add('${request.method} $path $body');
    sentHeaders.add(Map<String, String>.from(request.headers));
    rows.add({'title': 'from-server'});
    return _json(201, {'ok': true});
  }

  AdapterResponse _json(int status, Object? body) => AdapterResponse(
        statusCode: status,
        headers: const {'content-type': 'application/json'},
        bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      );

  @override
  void close() {}
}

void main() {
  group('E2E: offline write -> reconnect -> replay', () {
    test('an atMostOnce create is never delivered twice across passes',
        () async {
      final server = _FlakyServer();
      final queue = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: server,
          interceptors: [
            OfflineQueueInterceptor(
              store: queue,
              isOnline: () async => server.online,
              replaySafetyOf: (req) => req.method.toUpperCase() == 'POST'
                  ? ReplaySafety.atMostOnce
                  : ReplaySafety.atLeastOnce,
            ),
          ],
        ),
      );

      // --- offline: the write is captured, not delivered ---
      final offlineResult =
          await client.post<dynamic>('todos', const {'title': 'buy milk'});
      expect(offlineResult.isSuccess, isFalse);
      expect(server.accepted, isEmpty);
      expect(await queue.length, 1);

      // --- back online: one replay pass delivers it exactly once ---
      server.online = true;
      final replayer = OfflineQueueReplayer(store: queue, client: client);
      final report = await replayer.replay();

      expect(report.succeeded, 1);
      expect(server.accepted, hasLength(1));
      expect(await queue.length, 0);

      // --- a second pass (chatty connectivity listener) must not resend ---
      await replayer.replay();
      expect(server.accepted, hasLength(1),
          reason: 'the create must reach the server exactly once');
    });

    test('atLeastOnce survives a failed pass; atMostOnce is not resent',
        () async {
      final server = _FlakyServer();
      final queue = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: server,
          interceptors: [
            OfflineQueueInterceptor(
              store: queue,
              isOnline: () async => server.online,
              replaySafetyOf: (req) => req.method.toUpperCase() == 'POST'
                  ? ReplaySafety.atMostOnce
                  : ReplaySafety.atLeastOnce,
            ),
          ],
        ),
      );

      await client.post<dynamic>('todos', const {'title': 'create'});
      await client.put<dynamic>('todos/1', const {'title': 'rename'});
      expect(await queue.length, 2);

      // A replay attempted while STILL offline: every send fails transiently.
      final dropped = <String>[];
      final report = await OfflineQueueReplayer(
        store: queue,
        client: client,
        onDeadLetter: (r, _) => dropped.add(r.method),
      ).replay();

      // The idempotent PUT is kept for a later pass; the create is abandoned
      // rather than risking a duplicate, and is reported.
      expect(report.reEnqueued, 1);
      expect(report.deadLettered, 1);
      expect(dropped, ['POST']);

      final left = await queue.peekAll();
      expect(left.map((r) => r.method), ['PUT']);

      // Reconnect: only the surviving PUT is delivered.
      server.online = true;
      await OfflineQueueReplayer(store: queue, client: client).replay();
      expect(server.accepted, hasLength(1));
      expect(server.accepted.single, startsWith('PUT'));
    });

    test('optimistic mutate() honours atMostOnce and rolls back when dropped',
        () async {
      final server = _FlakyServer();
      final queue = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig(baseUrl: 'https://api.example.com', adapter: server),
      );
      final mutations = OfflineMutations(client: client, store: queue);

      // Local optimistic state, as an app would hold it.
      final localTodos = <String>[];

      await mutations.mutate<dynamic>(
        'POST',
        'todos',
        const {'title': 'buy milk'},
        replaySafety: ReplaySafety.atMostOnce,
        apply: () async => localTodos.add('buy milk'),
        rollback: () async => localTodos.remove('buy milk'),
      );

      // Applied immediately and queued with the requested guarantee.
      expect(localTodos, ['buy milk']);
      final queued = await queue.peekAll();
      expect(queued.single.replaySafety, ReplaySafety.atMostOnce);

      // Still offline when the replay runs: the write is abandoned, and the
      // optimistic row must be rolled back rather than left lying about.
      await mutations.buildReplayer().replay();

      expect(await queue.length, 0);
      expect(localTodos, isEmpty,
          reason: 'a dead-lettered atMostOnce mutation must roll back local '
              'state, not silently keep a row the server never got');
      expect(server.accepted, isEmpty);
    });

    test('optimistic mutate() defaults to atLeastOnce and commits on reconnect',
        () async {
      final server = _FlakyServer();
      final queue = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig(baseUrl: 'https://api.example.com', adapter: server),
      );
      final mutations = OfflineMutations(client: client, store: queue);
      final localTodos = <String>[];

      await mutations.mutate<dynamic>(
        'PUT',
        'todos/1',
        const {'title': 'renamed'},
        apply: () async => localTodos.add('renamed'),
        rollback: () async => localTodos.remove('renamed'),
      );
      expect((await queue.peekAll()).single.replaySafety,
          ReplaySafety.atLeastOnce);

      server.online = true;
      await mutations.buildReplayer().replay();

      expect(server.accepted, hasLength(1));
      expect(localTodos, ['renamed'], reason: 'a delivered write commits');
    });
  });

  group('E2E: replaying through the same client does not re-queue', () {
    // Regression: the README wires the replayer to the same client the offline
    // interceptor is on (the replay needs that client's auth and base URL). A
    // replay that failed while still offline used to be caught by that
    // interceptor and queued AGAIN, so the queue doubled on every pass and the
    // duplicates carried a reset attempt count — maxAttempts could never
    // dead-letter them, and every copy was delivered on reconnect.
    test('a failed replay pass does not grow the queue', () async {
      final server = _FlakyServer(); // offline
      final queue = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: server,
          interceptors: [OfflineQueueInterceptor(store: queue)],
        ),
      );

      await client.put<dynamic>('todos/1', const {'title': 'x'});
      expect(await queue.length, 1);

      final replayer = OfflineQueueReplayer(store: queue, client: client);
      await replayer.replay();
      expect(await queue.length, 1, reason: 'pass 1 must not duplicate');
      await replayer.replay();
      expect(await queue.length, 1, reason: 'pass 2 must not duplicate');

      // The attempt count actually advances, so maxAttempts can dead-letter.
      expect((await queue.peekAll()).single.attempts, 2);
    });

    test('attempts accumulate so a poison request is eventually dropped',
        () async {
      final server = _FlakyServer(); // stays offline
      final queue = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: server,
          interceptors: [OfflineQueueInterceptor(store: queue)],
        ),
      );
      await client.put<dynamic>('todos/1', const {'title': 'x'});

      // maxAttempts defaults to 3; three failing passes must exhaust it.
      final replayer = OfflineQueueReplayer(store: queue, client: client);
      await replayer.replay();
      await replayer.replay();
      final third = await replayer.replay();

      expect(third.deadLettered, 1);
      expect(await queue.length, 0,
          reason: 'maxAttempts must terminate a permanently failing request');
    });

    test('a replayed request still reaches the origin without the marker',
        () async {
      final server = _FlakyServer()..online = true;
      final queue = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: server,
          interceptors: [OfflineQueueInterceptor(store: queue)],
        ),
      );
      await queue.enqueue(QueuedRequest(
        id: 'q1',
        method: 'PUT',
        endpoint: 'todos/1',
        headers: const {'x-app': 'keep-me'},
        body: const {'title': 'x'},
        createdAt: DateTime(2024),
      ));

      await OfflineQueueReplayer(store: queue, client: client).replay();

      expect(server.accepted, hasLength(1));
      final sent = server.sentHeaders.single;
      expect(sent.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-fac-offline-replay')),
          reason: 'internal coordination headers must never hit the origin');
      expect(sent['x-app'], 'keep-me',
          reason: 'ordinary persisted headers still replay');
    });
  });

  group('E2E: replay safety survives real persistence', () {
    // The whole point of the mode is to be honoured after a crash, so it has
    // to round-trip through the real on-disk store, not just an in-memory one.
    test('a Hive-persisted atMostOnce record keeps its mode across a reopen',
        () async {
      final dir = await Directory.systemTemp.createTemp('replay_safety_e2e');
      Hive.init(dir.path);
      var box = await Hive.openBox<String>('replay_safety_queue');
      try {
        final server = _FlakyServer(); // offline
        final client = ApiClient(
          ApiClientConfig(
            baseUrl: 'https://api.example.com',
            adapter: server,
            interceptors: [
              OfflineQueueInterceptor(
                store: HiveOfflineQueueStore(box),
                replaySafetyOf: (req) => req.method.toUpperCase() == 'POST'
                    ? ReplaySafety.atMostOnce
                    : ReplaySafety.atLeastOnce,
              ),
            ],
          ),
        );

        await client.post<dynamic>('todos', const {'title': 'buy milk'});
        await client.put<dynamic>('todos/1', const {'title': 'rename'});

        // Simulate an app restart: close and reopen the box from disk.
        await box.close();
        box = await Hive.openBox<String>('replay_safety_queue');
        final reopened = HiveOfflineQueueStore(box);

        final modes = {
          for (final r in await reopened.peekAll()) r.method: r.replaySafety,
        };
        expect(modes['POST'], ReplaySafety.atMostOnce,
            reason: 'the mode must survive the crash it exists to protect '
                'against');
        expect(modes['PUT'], ReplaySafety.atLeastOnce);

        // And it is still honoured on the replay after the restart.
        server.online = true;
        final replayer =
            OfflineQueueReplayer(store: reopened, client: client);
        final report = await replayer.replay();
        expect(report.succeeded, 2);
        expect(server.accepted, hasLength(2));

        await replayer.replay();
        expect(server.accepted, hasLength(2),
            reason: 'a settled queue must not resend after a restart');
      } finally {
        if (box.isOpen) await box.close();
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    });
  });

  group('E2E: cache invalidation after a queued write lands', () {
    test('evicting the list endpoint makes the next read refetch', () async {
      final server = _FlakyServer()..online = true;
      final cacheStore = MemoryCacheStore();
      final cache = CacheInterceptor(
        store: cacheStore,
        defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(hours: 1)),
      );
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: server,
          interceptors: [cache],
        ),
      );

      // Prime the cache: the list is empty.
      final first = await client.get<Map<String, dynamic>>('todos');
      expect((first.data!['todos'] as List), isEmpty);

      // A write changes what the list returns.
      await client.post<dynamic>('todos', const {'title': 'buy milk'});

      // Without invalidation the cached (now stale) empty list is still served.
      final stale = await client.get<Map<String, dynamic>>('todos');
      expect((stale.data!['todos'] as List), isEmpty,
          reason: 'demonstrates the problem selective eviction solves');

      // Evict just that endpoint — not the whole store — and re-read.
      expect(await cache.evictEndpoint('/todos'), greaterThan(0));
      final fresh = await client.get<Map<String, dynamic>>('todos');
      expect((fresh.data!['todos'] as List), hasLength(1),
          reason: 'after eviction the list must come from the server');
    });

    test('evicting one endpoint leaves other cached endpoints intact',
        () async {
      final store = MemoryCacheStore();
      final cache = CacheInterceptor(
        store: store,
        defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(hours: 1)),
      );
      final adapter = MockAdapter()
        ..on('GET', '/todos', statusCode: 200, body: const {'v': 'todos'})
        ..on('GET', '/profile', statusCode: 200, body: const {'v': 'profile'});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: adapter,
          interceptors: [cache],
        ),
      );

      await client.get<dynamic>('todos');
      await client.get<dynamic>('profile');
      final hitsAfterPriming = adapter.received.length;

      await cache.evictEndpoint('/todos');

      // The profile read is still cached — no new transport hit.
      await client.get<dynamic>('profile');
      expect(adapter.received.length, hitsAfterPriming,
          reason: 'unrelated endpoints must survive a targeted eviction');

      // The todos read refetches.
      await client.get<dynamic>('todos');
      expect(adapter.received.length, hitsAfterPriming + 1);
    });

    test('staleWhileRevalidate(Duration.zero) is fallback-only, as documented',
        () async {
      final server = _FlakyServer()..online = true;
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: server,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy:
                  CachePolicy.staleWhileRevalidate(Duration.zero),
            ),
          ],
        ),
      );

      // Prime the cache while the list is empty.
      final primed = await client.get<Map<String, dynamic>>('todos');
      expect((primed.data!['todos'] as List), isEmpty);

      // The server's list changes. A zero TTL must never serve the cached
      // (empty) body on the request path — this read has to go to the network.
      server.rows.add({'title': 'added-server-side'});
      final live = await client.get<Map<String, dynamic>>('todos');
      expect((live.data!['todos'] as List), hasLength(1),
          reason: 'zero TTL must never serve the cache on the request path');

      // Offline: the last-known-good body answers instead of an error.
      server.online = false;
      final offline = await client.get<Map<String, dynamic>>('todos');
      expect(offline.isSuccess, isTrue,
          reason: 'the cache must still answer via the onError fallback');
      expect((offline.data!['todos'] as List), hasLength(1));
    });
  });
}
