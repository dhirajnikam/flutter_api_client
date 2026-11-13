import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A trivial local "store" the optimistic callbacks mutate, standing in for a
/// real Hive/Isar/Bloc-backed model.
class _FakeLocalDb {
  final Map<String, Object?> rows = {};
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
  group('OfflineMutations optimistic apply/rollback', () {
    test('applies locally and returns Success when online', () async {
      final db = _FakeLocalDb();
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/todos$'), statusCode: 201, body: {'id': 't1'});
      final store = InMemoryOfflineQueueStore();
      final mutations = OfflineMutations(client: _client(mock), store: store);

      final result = await mutations.mutate<dynamic>(
        'POST',
        'todos',
        {'title': 'buy milk'},
        apply: () async => db.rows['t1'] = 'buy milk',
        rollback: () async => db.rows.remove('t1'),
      );

      expect(result.isSuccess, true);
      expect(db.rows['t1'], 'buy milk'); // kept
      expect(await store.length, 0); // nothing queued
    });

    test('queues the request and keeps optimistic state when offline',
        () async {
      final db = _FakeLocalDb();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/todos$'), (_) async {
        throw const NetworkError('offline');
      });
      final store = InMemoryOfflineQueueStore();
      final mutations = OfflineMutations(client: _client(mock), store: store);

      final result = await mutations.mutate<dynamic>(
        'POST',
        'todos',
        {'title': 'buy milk'},
        priority: 5,
        apply: () async => db.rows['t1'] = 'buy milk',
        rollback: () async => db.rows.remove('t1'),
      );

      expect(result.isFailure, true);
      expect(result.error, isA<NetworkError>());
      expect(db.rows['t1'], 'buy milk'); // optimistic state kept
      expect(await store.length, 1);
      final queued = await store.drain();
      expect(queued.first.priority, 5);
      expect(queued.first.endpoint, 'todos');
    });

    test('rolls back immediately when the server rejects (non-transient)',
        () async {
      final db = _FakeLocalDb();
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/todos$'), statusCode: 422, body: {'e': 'bad'});
      final store = InMemoryOfflineQueueStore();
      final mutations = OfflineMutations(client: _client(mock), store: store);

      final result = await mutations.mutate<dynamic>(
        'POST',
        'todos',
        {'title': ''},
        apply: () async => db.rows['t1'] = 'x',
        rollback: () async => db.rows.remove('t1'),
      );

      expect(result.isFailure, true);
      expect(db.rows.containsKey('t1'), false); // rolled back
      expect(await store.length, 0); // not queued
    });

    test('does not persist the Authorization header', () async {
      final mock = MockAdapter();
      mock.onRequest('PUT', RegExp(r'/todos/1$'), (_) async {
        throw const NetworkError('offline');
      });
      final store = InMemoryOfflineQueueStore();
      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        tokenStorage: MemoryTokenStorage(accessToken: 'jwt'),
      ));
      final mutations = OfflineMutations(client: client, store: store);

      await mutations.mutate<dynamic>(
        'PUT',
        'todos/1',
        {'done': true},
        options: const RequestOptions(headers: {'x-tenant': 'a'}),
      );

      final queued = await store.drain();
      expect(queued.first.headers.containsKey('Authorization'), false);
      expect(queued.first.headers['x-tenant'], 'a');
    });

    test('rejects unsupported methods', () async {
      final mutations = OfflineMutations(
        client: _client(MockAdapter()),
        store: InMemoryOfflineQueueStore(),
      );
      expect(
        () => mutations.mutate<dynamic>('GET', 'todos', null),
        throwsArgumentError,
      );
    });
  });

  group('OfflineMutations + replayer rollback on dead-letter', () {
    test('rollback fires when a queued mutation is dead-lettered', () async {
      final db = _FakeLocalDb()..rows['t1'] = 'pending';
      final store = InMemoryOfflineQueueStore();

      // First send is offline (queues); replay hits a 400 -> dead-letter.
      var call = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/todos$'), (_) async {
        call++;
        if (call == 1) throw const NetworkError('offline');
        return _json(400, {'e': 'nope'});
      });
      final mutations = OfflineMutations(client: _client(mock), store: store);

      await mutations.mutate<dynamic>(
        'POST',
        'todos',
        {'title': 'x'},
        apply: () async => db.rows['t1'] = 'pending',
        rollback: () async => db.rows.remove('t1'),
      );
      expect(db.rows['t1'], 'pending'); // still optimistic

      final report = await mutations.buildReplayer().replay();
      expect(report.deadLettered, 1);
      expect(db.rows.containsKey('t1'), false); // rolled back on dead-letter
    });

    test('rollback does NOT fire on successful replay', () async {
      final db = _FakeLocalDb()..rows['t1'] = 'pending';
      final store = InMemoryOfflineQueueStore();
      var call = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/todos$'), (_) async {
        call++;
        if (call == 1) throw const NetworkError('offline');
        return _json(200, {'id': 't1'});
      });
      final mutations = OfflineMutations(client: _client(mock), store: store);

      await mutations.mutate<dynamic>(
        'POST',
        'todos',
        {'title': 'x'},
        apply: () async => db.rows['t1'] = 'pending',
        rollback: () async => db.rows.remove('t1'),
      );

      final report = await mutations.buildReplayer().replay();
      expect(report.succeeded, 1);
      expect(db.rows['t1'], 'pending'); // committed, not rolled back
    });
  });
}
