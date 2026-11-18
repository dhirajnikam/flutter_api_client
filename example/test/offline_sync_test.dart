import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_api_client_example/offline_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'writes queued offline upload order-first, then the fetches run',
    () async {
      final store = InMemoryOfflineQueueStore();
      var online = false;
      final mock = MockAdapter()
        ..onRequest('POST', RegExp(r'.*'), (_) async {
          if (!online) throw const NetworkError('offline');
          return AdapterResponse(
            statusCode: 201,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        })
        ..on('GET', RegExp(r'.*'), statusCode: 200, body: {'ok': true});
      final client = buildSyncClient(store, adapter: mock);
      final log = <String>[];
      final sync = buildSync(client, store, log: log.add);
      addTearDown(sync.dispose);

      await client.post<dynamic>('comments', {'n': 1});
      await client.post<dynamic>('posts', {'n': 2});
      expect(await store.length, 2);

      // Still offline: the order cannot go, so the item behind it is not tried.
      expect(await sync.runOnce(), isFalse);
      expect(log, ['upload POST posts reEnqueued']);

      log.clear();
      online = true;
      expect(await sync.runOnce(), isTrue);
      expect(log, [
        'upload POST posts succeeded',
        'upload POST comments succeeded',
        'fetch users/1 ok',
        'fetch todos/1 ok',
      ]);
    },
  );

  test('a background task waits for the running app to finish', () async {
    expect(await syncInRunningApp(), isNull); // no app: the task owns the queue

    var result = true;
    final port = serveBackgroundSync(() async => result);
    addTearDown(() {
      port.close();
      IsolateNameServer.removePortNameMapping(kSyncPort);
    });
    expect(await syncInRunningApp(), isTrue);
    result = false; // work left: the task must report it, not claim success
    expect(await syncInRunningApp(), isFalse);

    // An app that never answers must not hold the task past its time budget.
    final silent = serveBackgroundSync(() => Completer<bool>().future);
    addTearDown(silent.close);
    expect(
      await syncInRunningApp(timeout: const Duration(milliseconds: 50)),
      isFalse,
    );
  });
}
