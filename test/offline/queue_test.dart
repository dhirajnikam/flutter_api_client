import 'dart:convert';
import 'dart:io';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _HiveTestEnv {
  _HiveTestEnv({required this.dir, required this.name, required this.box});

  final Directory dir;
  final String name;
  Box<String> box;
}

Future<_HiveTestEnv> _openHiveBox(String suffix) async {
  final dir = await Directory.systemTemp.createTemp('offline_queue_$suffix');
  Hive.init(dir.path);
  final name = 'offline_queue_$suffix';
  final box = await Hive.openBox<String>(name);
  return _HiveTestEnv(dir: dir, name: name, box: box);
}

Future<void> _cleanupHiveBox(_HiveTestEnv env) async {
  if (env.box.isOpen) {
    await env.box.close();
  }
  if (env.dir.existsSync()) {
    await env.dir.delete(recursive: true);
  }
}

void main() {
  group('InMemoryOfflineQueueStore', () {
    test('enqueue adds item and length reflects it', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(
        QueuedRequest(
          id: '1',
          method: 'POST',
          endpoint: '/items',
          headers: const {},
          createdAt: DateTime(2024),
        ),
      );
      expect(await store.length, 1);
    });

    test('drain returns all items and empties store', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(
        QueuedRequest(
            id: 'a',
            method: 'POST',
            endpoint: '/a',
            headers: const {},
            createdAt: DateTime(2024)),
      );
      await store.enqueue(
        QueuedRequest(
            id: 'b',
            method: 'PUT',
            endpoint: '/b',
            headers: const {},
            createdAt: DateTime(2024)),
      );
      final drained = await store.drain();
      expect(drained, hasLength(2));
      expect(await store.length, 0);
    });

    test('remove deletes item by id', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(
        QueuedRequest(
            id: 'x',
            method: 'DELETE',
            endpoint: '/x',
            headers: const {},
            createdAt: DateTime(2024)),
      );
      await store.remove('x');
      expect(await store.length, 0);
    });

    test('QueuedRequest.toJson serialises correctly', () {
      final req = QueuedRequest(
        id: '42',
        method: 'PATCH',
        endpoint: '/thing',
        headers: const {'x-foo': 'bar'},
        body: {'key': 'val'},
        createdAt: DateTime(2024, 1, 15),
      );
      final json = req.toJson();
      expect(json['id'], '42');
      expect(json['method'], 'PATCH');
      expect(json['endpoint'], '/thing');
      expect(json['headers'], {'x-foo': 'bar'});
      expect(json['body'], {'key': 'val'});
      expect(json['createdAt'], contains('2024-01-15'));
    });

    test('QueuedRequest.fromJson round-trips toJson output', () {
      final req = QueuedRequest(
        id: '42',
        method: 'PATCH',
        endpoint: '/thing',
        headers: const {'x-foo': 'bar'},
        body: {'key': 'val'},
        createdAt: DateTime(2024, 1, 15),
      );

      final decoded = QueuedRequest.fromJson(req.toJson());
      expect(decoded.id, req.id);
      expect(decoded.method, req.method);
      expect(decoded.endpoint, req.endpoint);
      expect(decoded.headers, req.headers);
      expect(decoded.body, req.body);
      expect(decoded.createdAt, req.createdAt);
    });
  });

  group('HiveOfflineQueueStore', () {
    test('enqueue persists item and length reflects it', () async {
      final env = await _openHiveBox('enqueue');
      addTearDown(() => _cleanupHiveBox(env));

      final store = HiveOfflineQueueStore(env.box);
      await store.enqueue(
        QueuedRequest(
          id: '1',
          method: 'POST',
          endpoint: '/items',
          headers: const {},
          body: {'ok': true},
          createdAt: DateTime(2024),
        ),
      );

      expect(await store.length, 1);
    });

    test('drain returns persisted items in createdAt order and clears box',
        () async {
      final env = await _openHiveBox('drain');
      addTearDown(() => _cleanupHiveBox(env));

      final store = HiveOfflineQueueStore(env.box);
      await store.enqueue(
        QueuedRequest(
          id: 'later',
          method: 'POST',
          endpoint: '/later',
          headers: const {},
          createdAt: DateTime(2024, 1, 2),
        ),
      );
      await store.enqueue(
        QueuedRequest(
          id: 'earlier',
          method: 'POST',
          endpoint: '/earlier',
          headers: const {},
          createdAt: DateTime(2024),
        ),
      );

      final drained = await store.drain();

      expect(drained.map((e) => e.id).toList(), ['earlier', 'later']);
      expect(await store.length, 0);
    });

    test('remove deletes persisted item by id', () async {
      final env = await _openHiveBox('remove');
      addTearDown(() => _cleanupHiveBox(env));

      final store = HiveOfflineQueueStore(env.box);
      await store.enqueue(
        QueuedRequest(
          id: 'x',
          method: 'DELETE',
          endpoint: '/x',
          headers: const {},
          createdAt: DateTime(2024),
        ),
      );

      await store.remove('x');

      expect(await store.length, 0);
    });

    test('reopening the same box preserves queued items', () async {
      final env = await _openHiveBox('reopen');
      addTearDown(() => _cleanupHiveBox(env));

      final store = HiveOfflineQueueStore(env.box);
      await store.enqueue(
        QueuedRequest(
          id: 'persisted',
          method: 'POST',
          endpoint: '/persisted',
          headers: const {},
          body: {'v': 1},
          createdAt: DateTime(2024),
        ),
      );
      await env.box.close();

      final reopened = await Hive.openBox<String>(env.name);
      env.box = reopened;

      final reopenedStore = HiveOfflineQueueStore(reopened);
      final drained = await reopenedStore.drain();

      expect(drained, hasLength(1));
      expect(drained.first.id, 'persisted');
      expect(drained.first.body, {'v': 1});
    });
  });

  group('InMemoryOfflineQueueStore.drain — ordering', () {
    test('returns requests oldest createdAt first regardless of enqueue order',
        () async {
      final store = InMemoryOfflineQueueStore();
      final older = QueuedRequest(
        id: 'a',
        method: 'POST',
        endpoint: '/a',
        headers: const {},
        createdAt: DateTime.utc(2020),
      );
      final newer = QueuedRequest(
        id: 'b',
        method: 'POST',
        endpoint: '/b',
        headers: const {},
        createdAt: DateTime.utc(2021),
      );

      await store.enqueue(newer);
      await store.enqueue(older);

      final drained = await store.drain();
      expect(drained.map((r) => r.id).toList(), ['a', 'b']);
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

  group('QueuedRequest.priority', () {
    test('round-trips through JSON', () {
      final req = QueuedRequest(
        id: '1',
        method: 'POST',
        endpoint: '/x',
        headers: const {},
        createdAt: DateTime(2024),
        priority: 7,
      );
      expect(req.toJson()['priority'], 7);
      expect(QueuedRequest.fromJson(req.toJson()).priority, 7);
    });

    test('defaults to 0 and tolerates a missing json field', () {
      final json = {
        'id': '1',
        'method': 'POST',
        'endpoint': '/x',
        'headers': <String, String>{},
        'createdAt': DateTime(2024).toIso8601String(),
      };
      expect(QueuedRequest.fromJson(json).priority, 0);
    });

    test('withAttempt preserves priority', () {
      final req = QueuedRequest(
        id: '1',
        method: 'POST',
        endpoint: '/x',
        headers: const {},
        createdAt: DateTime(2024),
        priority: 3,
      );
      expect(req.withAttempt().priority, 3);
    });
  });

  group('drain ordering (priority then createdAt)', () {
    test('InMemory store drains highest priority first, then oldest', () async {
      final store = InMemoryOfflineQueueStore();
      // Enqueue out of order on both axes.
      await store.enqueue(QueuedRequest(
          id: 'low-old',
          method: 'POST',
          endpoint: '/a',
          headers: const {},
          createdAt: DateTime(2024)));
      await store.enqueue(QueuedRequest(
          id: 'high',
          method: 'POST',
          endpoint: '/b',
          headers: const {},
          createdAt: DateTime(2024, 1, 3),
          priority: 10));
      await store.enqueue(QueuedRequest(
          id: 'low-new',
          method: 'POST',
          endpoint: '/c',
          headers: const {},
          createdAt: DateTime(2024, 1, 2)));

      final drained = await store.drain();
      expect(drained.map((e) => e.id).toList(), ['high', 'low-old', 'low-new']);
    });
  });

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
}
