import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart' hide within;

import '../support/liveness.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// Offline store seeded with a fixed list whose [enqueue] always throws.
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

/// Builds a JSON [AdapterResponse] for dynamic mock responders.
AdapterResponse _json(int statusCode, Object? body) => AdapterResponse(
      statusCode: statusCode,
      headers: const {'content-type': 'application/json'},
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );

ApiClient _client(MockAdapter mock) => ApiClient(
      ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
    );

void main() {
  // ===========================================================================
  // Offline queue ordering, attempt counting, dead-lettering,
  //   and re-enqueue-failure survival.
  //   (1) replay processes in createdAt order. (2) every drained request is
  //   accounted for exactly once (succeeded+reEnqueued+deadLettered == total).
  //   (3) a transient failure increments attempts and is re-enqueued until it
  //   reaches maxAttempts, then dead-lettered (no infinite loop). (4) one
  //   enqueue failure mid-loop does not abandon the remaining requests.
  // ===========================================================================
  group('offline queue replay', () {
    test('conservation: every drained request is accounted for exactly once',
        () async {
      final store = InMemoryOfflineQueueStore();
      // Three requests: one will succeed, one transient (re-enqueue), one
      // permanently rejected (dead-letter).
      await store.enqueue(QueuedRequest(
          id: 'ok',
          method: 'POST',
          endpoint: '/ok',
          headers: const {},
          createdAt: DateTime(2024)));
      await store.enqueue(QueuedRequest(
          id: 'transient',
          method: 'POST',
          endpoint: '/transient',
          headers: const {},
          createdAt: DateTime(2024, 1, 2)));
      await store.enqueue(QueuedRequest(
          id: 'reject',
          method: 'POST',
          endpoint: '/reject',
          headers: const {},
          createdAt: DateTime(2024, 1, 3)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/ok$'), statusCode: 200, body: {'ok': true});
      mock.onRequest('POST', RegExp(r'/transient$'),
          (_) async => throw const NetworkError('offline'));
      mock.on('POST', RegExp(r'/reject$'), statusCode: 400, body: {'no': true});

      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      final report = await within(
          OfflineQueueReplayer(store: store, client: client).replay());

      expect(report.total, 3);
      expect(report.succeeded, 1);
      expect(report.reEnqueued, 1);
      expect(report.deadLettered, 1);
      // Conservation law: no request vanished and none was double-counted.
      expect(report.succeeded + report.reEnqueued + report.deadLettered,
          report.total);
    });

    test('replay order is createdAt-ascending (FIFO by creation)', () async {
      final store = InMemoryOfflineQueueStore();
      // Inserted out of order.
      await store.enqueue(QueuedRequest(
          id: 'c',
          method: 'POST',
          endpoint: '/c',
          headers: const {},
          createdAt: DateTime(2024, 3)));
      await store.enqueue(QueuedRequest(
          id: 'a',
          method: 'POST',
          endpoint: '/a',
          headers: const {},
          createdAt: DateTime(2024)));
      await store.enqueue(QueuedRequest(
          id: 'b',
          method: 'POST',
          endpoint: '/b',
          headers: const {},
          createdAt: DateTime(2024, 2)));

      final order = <String>[];
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/[abc]$'), (req) async {
        order.add(req.url.path);
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      await within(OfflineQueueReplayer(store: store, client: client).replay());
      expect(order, ['/a', '/b', '/c'], reason: 'FIFO by createdAt');
    });

    test('poison message is dead-lettered after maxAttempts (no infinite loop)',
        () async {
      // A request that ALWAYS fails transiently must eventually stop. Start it
      // near the ceiling so a single replay pass dead-letters it.
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'poison',
          method: 'POST',
          endpoint: '/poison',
          headers: const {},
          createdAt: DateTime(2024),
          attempts: 1));
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/poison$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      // maxAttempts=2: attempts becomes 2 (>=2) => dead-lettered, NOT re-queued.
      final report = await within(
          OfflineQueueReplayer(store: store, client: client, maxAttempts: 2)
              .replay());
      expect(report.deadLettered, 1);
      expect(report.reEnqueued, 0);
      expect(await store.length, 0, reason: 'poison dropped, not looping');
    });

    test('attempt count increments across replay passes', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'r',
          method: 'POST',
          endpoint: '/r',
          headers: const {},
          createdAt: DateTime(2024)));
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/r$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      final replayer =
          OfflineQueueReplayer(store: store, client: client, maxAttempts: 5);

      await within(replayer.replay());
      final after1 = await store.drain();
      expect(after1.single.attempts, 1);
      // put it back for a second pass
      await store.enqueue(after1.single);
      await within(replayer.replay());
      final after2 = await store.drain();
      expect(after2.single.attempts, 2, reason: 'attempts are monotone');
    });

    test('re-enqueue failure mid-loop does not abandon remaining requests',
        () async {
      // The store's enqueue throws (disk full). The loop must survive: both
      // requests are processed, the failed re-enqueue is counted as a
      // dead-letter, nothing is silently dropped.
      final store = _ThrowOnEnqueueStore([
        QueuedRequest(
            id: '1',
            method: 'POST',
            endpoint: '/a',
            headers: const {},
            createdAt: DateTime(2024)),
        QueuedRequest(
            id: '2',
            method: 'POST',
            endpoint: '/b',
            headers: const {},
            createdAt: DateTime(2024, 1, 2)),
      ]);
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/[ab]$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      final report = await within(
          OfflineQueueReplayer(store: store, client: client).replay());
      expect(report.total, 2);
      expect(report.deadLettered, 2);
      expect(store.enqueueAttempts, 2,
          reason: 'both processed despite enqueue throwing');
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
  });

  group('OfflineQueueReplayer.compare override', () {
    test('custom comparator reorders the drained batch', () async {
      final store = InMemoryOfflineQueueStore();
      final seen = <String>[];
      final mock = MockAdapter();
      // Record replay order; succeed everything.
      for (final ep in ['/a', '/b', '/c']) {
        mock.onRequest('POST', RegExp('$ep\$'), (req) async {
          seen.add(ep);
          return _json(200, {'ok': true});
        });
      }
      for (final id in ['a', 'b', 'c']) {
        await store.enqueue(QueuedRequest(
            id: id,
            method: 'POST',
            endpoint: '/$id',
            headers: const {},
            createdAt: DateTime(2024)));
      }

      final replayer = OfflineQueueReplayer(
        store: store,
        client: _client(mock),
        // Reverse-alphabetical by endpoint.
        compare: (x, y) => y.endpoint.compareTo(x.endpoint),
      );
      final report = await replayer.replay();

      expect(report.succeeded, 3);
      expect(seen, ['/c', '/b', '/a']);
    });
  });

  group('OfflineQueueReplayer — replay fidelity', () {
    test('replays with the persisted query parameters and base URL', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
        id: '1',
        method: 'POST',
        endpoint: 'save',
        headers: const {},
        body: {'v': 1},
        createdAt: DateTime(2024),
        queryParameters: const {'draft': true},
        baseUrlOverride: 'https://tenant.example.com',
      ));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/save$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();

      expect(report.succeeded, 1);
      final sent = mock.received.single;
      expect(sent.url.host, 'tenant.example.com');
      expect(sent.url.queryParameters['draft'], 'true');
    });

    test('replays QUERY requests with the QUERY method', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
        id: '1',
        method: 'QUERY',
        endpoint: 'search',
        headers: const {},
        body: {'q': 'hats'},
        createdAt: DateTime(2024),
      ));

      final mock = MockAdapter();
      mock.on('QUERY', RegExp(r'/search$'), statusCode: 200, body: []);
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();
      expect(report.succeeded, 1);
      expect(mock.received.single.method, 'QUERY');
    });

    test(
        'peekable store keeps requests persisted until settled '
        '(success removes, transient rewrites with bumped attempts)', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'ok',
          method: 'POST',
          endpoint: '/ok',
          headers: const {},
          createdAt: DateTime(2024)));
      await store.enqueue(QueuedRequest(
          id: 'flaky',
          method: 'POST',
          endpoint: '/flaky',
          headers: const {},
          createdAt: DateTime(2024, 1, 2)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/ok$'), statusCode: 200, body: {'ok': true});
      mock.onRequest('POST', RegExp(r'/flaky$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();

      expect(report.succeeded, 1);
      expect(report.reEnqueued, 1);
      final remaining = await store.peekAll();
      expect(remaining.single.id, 'flaky');
      expect(remaining.single.attempts, 1);
    });

    test('concurrent replay() calls share a single pass (no double-send)',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: '1',
          method: 'POST',
          endpoint: '/slow',
          headers: const {},
          createdAt: DateTime(2024)));

      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/slow$'), (_) async {
        sends++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      final replayer = OfflineQueueReplayer(store: store, client: client);

      final first = replayer.replay();
      final second = replayer.replay();
      final reports = await Future.wait([first, second]);

      expect(sends, 1, reason: 'the queue must not be replayed twice');
      expect(reports[0].succeeded, 1);
      expect(identical(reports[0], reports[1]), isTrue,
          reason: 'overlapping calls await the same pass');

      // A replay AFTER the pass completed starts a fresh pass.
      final after = await replayer.replay();
      expect(after.total, 0, reason: 'queue is empty on the next pass');
    });

    test('onDeadLetter fires with the request and the final error', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'rejected',
          method: 'POST',
          endpoint: '/rejected',
          headers: const {},
          createdAt: DateTime(2024)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/rejected$'),
          statusCode: 422, body: {'error': 'invalid'});
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final dropped = <(QueuedRequest, ApiException?)>[];
      final report = await OfflineQueueReplayer(
        store: store,
        client: client,
        onDeadLetter: (req, err) => dropped.add((req, err)),
      ).replay();

      expect(report.deadLettered, 1);
      expect(dropped, hasLength(1));
      expect(dropped.single.$1.id, 'rejected');
      expect(dropped.single.$2, isA<HttpError>());
      expect(await store.length, 0);
    });
  });
}
