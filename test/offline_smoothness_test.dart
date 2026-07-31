import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('QueuedRequest — query parameters and base URL round-trip', () {
    test('toJson/fromJson round-trips queryParameters and baseUrlOverride', () {
      final req = QueuedRequest(
        id: '1',
        method: 'POST',
        endpoint: 'items',
        headers: const {'x-a': 'b'},
        body: {'k': 'v'},
        createdAt: DateTime(2024, 1, 15),
        queryParameters: const {
          'page': 2,
          'tags': ['a', 'b']
        },
        baseUrlOverride: 'https://other.example.com',
      );

      final back = QueuedRequest.fromJson(
        jsonDecode(jsonEncode(req.toJson())) as Map<String, Object?>,
      );

      expect(back.queryParameters, {
        'page': 2,
        'tags': ['a', 'b'],
      });
      expect(back.baseUrlOverride, 'https://other.example.com');
    });

    test('legacy records without the new fields still parse', () {
      final legacy = <String, Object?>{
        'id': 'old',
        'method': 'POST',
        'endpoint': '/x',
        'headers': <String, Object?>{},
        'createdAt': DateTime(2024).toIso8601String(),
        'attempts': 1,
      };
      final parsed = QueuedRequest.tryFromJson(legacy);
      expect(parsed, isNotNull);
      expect(parsed!.queryParameters, isNull);
      expect(parsed.baseUrlOverride, isNull);
    });

    test('withAttempt preserves queryParameters and baseUrlOverride', () {
      final req = QueuedRequest(
        id: '1',
        method: 'POST',
        endpoint: 'items',
        headers: const {},
        createdAt: DateTime(2024),
        queryParameters: const {'a': 1},
        baseUrlOverride: 'https://b.example.com',
      );
      final next = req.withAttempt();
      expect(next.attempts, 1);
      expect(next.queryParameters, {'a': 1});
      expect(next.baseUrlOverride, 'https://b.example.com');
    });
  });

  group('peekAll — non-destructive reads', () {
    test('InMemoryOfflineQueueStore.peekAll returns sorted without removing',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'b',
          method: 'POST',
          endpoint: '/b',
          headers: const {},
          createdAt: DateTime(2024, 2)));
      await store.enqueue(QueuedRequest(
          id: 'a',
          method: 'POST',
          endpoint: '/a',
          headers: const {},
          createdAt: DateTime(2024)));

      final peeked = await store.peekAll();
      expect(peeked.map((e) => e.id).toList(), ['a', 'b']);
      expect(await store.length, 2, reason: 'peek must not remove');
    });

    test('HiveOfflineQueueStore.peekAll returns sorted without removing',
        () async {
      final dir = await Directory.systemTemp.createTemp('offline_peek');
      Hive.init(dir.path);
      final box = await Hive.openBox<String>('offline_peek');
      addTearDown(() async {
        if (box.isOpen) await box.close();
        if (dir.existsSync()) await dir.delete(recursive: true);
      });

      final store = HiveOfflineQueueStore(box);
      await store.enqueue(QueuedRequest(
          id: 'later',
          method: 'POST',
          endpoint: '/later',
          headers: const {},
          createdAt: DateTime(2024, 3)));
      await store.enqueue(QueuedRequest(
          id: 'earlier',
          method: 'POST',
          endpoint: '/earlier',
          headers: const {},
          createdAt: DateTime(2024)));

      final peeked = await store.peekAll();
      expect(peeked.map((e) => e.id).toList(), ['earlier', 'later']);
      expect(await store.length, 2, reason: 'peek must not remove');
    });
  });

  group('OfflineQueueInterceptor — capture fidelity', () {
    test('queued record preserves queryParameters and baseUrlOverride',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(store: store, isOnline: () async => false),
        ],
      ));

      await client.post<dynamic>(
        'save',
        {'v': 1},
        options: const RequestOptions(
          queryParameters: {'draft': true, 'rev': 7},
          baseUrlOverride: 'https://tenant.example.com',
        ),
      );

      final queued = (await store.peekAll()).single;
      expect(queued.queryParameters, {'draft': true, 'rev': 7});
      expect(queued.baseUrlOverride, 'https://tenant.example.com');
    });

    test('multipart requests are not queued (cannot be replayed faithfully)',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/upload$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(store: store, isOnline: () async => false),
        ],
      ));

      final result = await client.post<dynamic>(
        'upload',
        {'file': 'x'},
        isMultipart: true,
      );

      expect(result.isSuccess, false);
      expect(await store.length, 0);
    });

    test('a throwing store does not mask the original network error', () async {
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(
            store: _AlwaysThrowStore(),
            isOnline: () async => false,
          ),
        ],
      ));

      final result = await client.post<dynamic>('save', {'v': 1});
      expect(result.error, isA<NetworkError>(),
          reason: 'the enqueue failure must not replace the network error');
    });

    test('onQueued fires with the stored record', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      QueuedRequest? seen;
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(
            store: store,
            isOnline: () async => false,
            onQueued: (q) => seen = q,
          ),
        ],
      ));

      await client.post<dynamic>('save', {'v': 1});
      expect(seen, isNotNull);
      expect(seen!.endpoint, 'save');
      expect(await store.length, 1);
    });

    test('a throwing onQueued listener does not mask the network error',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(
            store: store,
            isOnline: () async => false,
            onQueued: (_) => throw StateError('listener bug'),
          ),
        ],
      ));

      final result = await client.post<dynamic>('save', {'v': 1});
      expect(result.error, isA<NetworkError>());
      expect(await store.length, 1, reason: 'request still queued');
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

    test('replays QUERY requests through client.query', () async {
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

/// A store whose writes always fail (e.g. disk full / unserializable body).
class _AlwaysThrowStore implements OfflineQueueStore {
  @override
  Future<void> enqueue(QueuedRequest request) async {
    throw StateError('disk full');
  }

  @override
  Future<List<QueuedRequest>> drain() async => const [];

  @override
  Future<void> remove(String id) async {}

  @override
  Future<int> get length async => 0;
}
