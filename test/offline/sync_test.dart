import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

ApiClient _client(MockAdapter mock) => ApiClient(
      ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
    );

void main() {
  group('OfflineSyncManager', () {
    test('replays automatically when connectivity returns', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: '1',
          method: 'POST',
          endpoint: 'save',
          headers: const {},
          body: {'v': 1},
          createdAt: DateTime(2024)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/save$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final connectivity = StreamController<bool>();
      final reports = <OfflineReplayReport>[];
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        onlineStream: connectivity.stream,
        onReport: reports.add,
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();

      expect(reports, hasLength(1));
      expect(reports.single.succeeded, 1);
      expect(await store.length, 0);
    });

    test('schedules another pass while transient failures remain', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'flaky',
          method: 'POST',
          endpoint: 'flaky',
          headers: const {},
          createdAt: DateTime(2024)));

      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/flaky$'), (_) async {
        sends++;
        if (sends == 1) throw const NetworkError('still offline-ish');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final connectivity = StreamController<bool>();
      final reports = <OfflineReplayReport>[];
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        onlineStream: connectivity.stream,
        retryDelay: const Duration(milliseconds: 50),
        onReport: reports.add,
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();
      expect(reports, hasLength(1));
      expect(reports.first.reEnqueued, 1);

      // The retry timer fires and the second pass delivers the request.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(reports, hasLength(2));
      expect(reports.last.succeeded, 1);
      expect(await store.length, 0);
    });

    test('going offline cancels the scheduled retry pass', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'x',
          method: 'POST',
          endpoint: 'x',
          headers: const {},
          createdAt: DateTime(2024)));

      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/x$'), (_) async {
        sends++;
        throw const NetworkError('offline');
      });
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final connectivity = StreamController<bool>();
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        onlineStream: connectivity.stream,
        retryDelay: const Duration(milliseconds: 50),
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();
      expect(sends, 1);

      connectivity.add(false); // cancels the pending retry
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sends, 1, reason: 'no retry pass while offline');
      expect(await store.length, 1, reason: 'request stays queued');
    });

    test('replayOnStart drains writes queued in a previous session', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'boot',
          method: 'POST',
          endpoint: 'boot',
          headers: const {},
          createdAt: DateTime(2024)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/boot$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        replayOnStart: true,
      );
      addTearDown(sync.dispose);

      sync.start();
      await pumpEventQueue();
      expect(await store.length, 0);
    });
  });

  group('OfflineAutoReplay', () {
    test('replays when connectivity emits online', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'q1',
          method: 'POST',
          endpoint: '/save',
          headers: const {},
          createdAt: DateTime(2024)));
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/save$'), statusCode: 200, body: {'ok': true});

      final reports = <OfflineReplayReport>[];
      final auto = OfflineAutoReplay(
        replayer: OfflineQueueReplayer(store: store, client: _client(mock)),
        onReplayed: reports.add,
      );
      final conn = StreamController<bool>();
      auto.bind(conn.stream);

      conn.add(false); // offline: no replay
      await Future<void>.delayed(Duration.zero);
      expect(reports, isEmpty);

      conn.add(true); // online: replay
      // Let the async trigger complete.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(reports, hasLength(1));
      expect(reports.first.succeeded, 1);
      expect(await store.length, 0);

      await auto.dispose();
      await conn.close();
    });
  });
}
