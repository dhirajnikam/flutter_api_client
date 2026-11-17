import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

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

  group('OfflineSyncManager fetchSteps', () {
    QueuedRequest queued(String id) => QueuedRequest(
        id: id,
        method: 'POST',
        endpoint: id,
        headers: const {},
        createdAt: DateTime(2024));

    test('run in order after the uploads, once per overlapping trigger',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(queued('save'));
      final log = <String>[];
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'), (_) async {
        log.add('upload');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });

      final connectivity = StreamController<bool>();
      final reports = <OfflineReplayReport>[];
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: _client(mock)),
        onlineStream: connectivity.stream,
        onReport: reports.add,
        fetchSteps: [
          () async {
            log.add('fetch a');
            return true;
          },
          () async {
            log.add('fetch b');
            return true;
          },
        ],
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity
        ..add(true)
        ..add(true);
      await sync.syncNow();
      await pumpEventQueue();

      expect(log, ['upload', 'fetch a', 'fetch b']);
      expect(reports, hasLength(1));
    });

    test('are skipped while uploads are still queued, then run on the retry',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(queued('flaky'));
      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/flaky$'), (_) async {
        if (++sends == 1) throw const NetworkError('dropped');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });

      var fetches = 0;
      final connectivity = StreamController<bool>();
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: _client(mock)),
        onlineStream: connectivity.stream,
        retryDelay: const Duration(milliseconds: 50),
        fetchSteps: [() async => ++fetches > 0],
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();
      expect(fetches, 0, reason: 'a write is still queued');

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fetches, 1);
    });

    test('a failing or throwing step stops the sequence and is retried',
        () async {
      final log = <String>[];
      var calls = 0;
      final connectivity = StreamController<bool>();
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(
            store: InMemoryOfflineQueueStore(), client: _client(MockAdapter())),
        onlineStream: connectivity.stream,
        retryDelay: const Duration(milliseconds: 50),
        fetchSteps: [
          () async {
            log.add('a');
            switch (++calls) {
              case 1:
                return false;
              case 2:
                throw StateError('boom');
            }
            return true;
          },
          () async {
            log.add('b');
            return true;
          },
        ],
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();
      expect(log, ['a']);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(log, ['a', 'a', 'a', 'b']);
    });
  });

  group('OfflineSyncManager.runOnce (background task, no start/stream)', () {
    test('uploads, fetches, and reports whether work is left', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'save',
          method: 'POST',
          endpoint: 'save',
          headers: const {},
          createdAt: DateTime(2024)));
      var online = false;
      final log = <String>[];
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'), (_) async {
        if (!online) throw const NetworkError('dropped');
        log.add('upload');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: _client(mock)),
        fetchSteps: [
          () async {
            log.add('fetch');
            return true;
          },
        ],
      );
      addTearDown(sync.dispose);

      expect(await sync.runOnce(), isFalse, reason: 'upload still queued');
      expect(log, isEmpty);

      online = true;
      expect(await sync.runOnce(), isTrue);
      expect(log, ['upload', 'fetch']);

      await sync.dispose();
      expect(await sync.runOnce(), isFalse);
    });
  });

  group('terminated app: a cold start drains what an earlier run queued', () {
    test('runOnce on a reopened Hive box uploads in order, then fetches',
        () async {
      final dir = await Directory.systemTemp.createTemp('offline_cold');
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });

      // Session 1: the app queues two writes while offline, then is killed.
      var box = await Hive.openBox<String>('cold_queue');
      final offline = MockAdapter()
        ..onRequest('POST', RegExp(r'.*'),
            (_) async => throw const NetworkError('offline'));
      final first = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: offline,
        interceptors: [
          OfflineQueueInterceptor(
            store: HiveOfflineQueueStore(box),
            priorityOf: (req) => req.endpoint == 'order' ? 10 : 0,
          ),
        ],
      ));
      await first.post<dynamic>('item', {'n': 1});
      await first.post<dynamic>('order', {'n': 2});
      await box.close();

      // Session 2: a background task with nothing but the persisted box.
      box = await Hive.openBox<String>('cold_queue');
      final log = <String>[];
      final online = MockAdapter()
        ..onRequest('POST', RegExp(r'.*'), (req) async {
          log.add('upload ${req.url.pathSegments.last}');
          return AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              bodyBytes: _b('{}'));
        });
      final store = HiveOfflineQueueStore(box);
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(
            store: store, client: _client(online), haltOnFailure: true),
        fetchSteps: [
          () async {
            log.add('fetch');
            return true;
          },
        ],
      );

      expect(await sync.runOnce(), isTrue);
      expect(log, ['upload order', 'upload item', 'fetch']);
      expect(await store.length, 0);
      await sync.dispose();
    });
  });

  group('OfflineQueueReplayer haltOnFailure', () {
    for (final peekable in [true, false]) {
      test('stops at the first re-enqueued request (peekable: $peekable)',
          () async {
        final OfflineQueueStore store = peekable
            ? InMemoryOfflineQueueStore()
            : _DrainOnlyStore(InMemoryOfflineQueueStore());
        for (final (i, id) in ['parent', 'child', 'grandchild'].indexed) {
          await store.enqueue(QueuedRequest(
              id: id,
              method: 'POST',
              endpoint: id,
              headers: const {},
              createdAt: DateTime(2024, 1, 1 + i)));
        }
        final sent = <String>[];
        var online = false;
        final mock = MockAdapter();
        mock.onRequest('POST', RegExp(r'.*'), (req) async {
          sent.add(req.url.pathSegments.last);
          if (!online) throw const NetworkError('dropped');
          return AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              bodyBytes: _b('{}'));
        });
        final replayer = OfflineQueueReplayer(
            store: store, client: _client(mock), haltOnFailure: true);

        final first = await replayer.replay();
        expect(sent, ['parent'], reason: 'nothing jumps ahead of parent');
        expect(first.reEnqueued, 1);
        expect(await store.length, 3, reason: 'the tail stays queued');

        online = true;
        sent.clear();
        final second = await replayer.replay();
        expect(sent, ['parent', 'child', 'grandchild']);
        expect(second.succeeded, 3);
      });
    }
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

/// Hides `peekAll`, so the replayer takes its drain-based path.
class _DrainOnlyStore implements OfflineQueueStore {
  _DrainOnlyStore(this._inner);
  final InMemoryOfflineQueueStore _inner;

  @override
  Future<void> enqueue(QueuedRequest request) => _inner.enqueue(request);
  @override
  Future<List<QueuedRequest>> drain() => _inner.drain();
  @override
  Future<void> remove(String id) => _inner.remove(id);
  @override
  Future<int> get length => _inner.length;
}
