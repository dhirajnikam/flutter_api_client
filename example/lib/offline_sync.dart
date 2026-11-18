import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_api_client/flutter_api_client.dart';

/// The sync sequence, defined once and shared by the running app and the OS
/// background task: queued writes go out first (orders before their items),
/// then the fetches run in list order.
///
/// Plugin-free on purpose, so it runs in a test and in a background isolate.
/// The hand-off between the two isolates is at the bottom of this file.

/// Client whose failed writes are queued into [store] while offline.
///
/// [onQueued] fires each time a write is queued; the app uses it to ask the OS
/// for a background run as soon as the network is back.
ApiClient buildSyncClient(
  OfflineQueueStore store, {
  HttpAdapter? adapter,
  void Function(QueuedRequest queued)? onQueued,
}) => ApiClient(
  ApiClientConfig(
    baseUrl: 'https://jsonplaceholder.typicode.com',
    adapter: adapter,
    interceptors: [
      OfflineQueueInterceptor(
        store: store,
        onQueued: onQueued,
        // An order must reach the server before the items that refer to it.
        priorityOf: (req) => req.endpoint == 'posts' ? 10 : 0,
      ),
    ],
  ),
);

OfflineSyncManager buildSync(
  ApiClient client,
  OfflineQueueStore store, {
  Stream<bool>? onlineStream,
  required void Function(String line) log,
}) {
  Future<bool> fetch(String endpoint) async {
    final result = await client.get<dynamic>(endpoint);
    log('fetch $endpoint ${result.isSuccess ? 'ok' : 'failed'}');
    return result.isSuccess;
  }

  return OfflineSyncManager(
    replayer: OfflineQueueReplayer(
      store: store,
      client: client,
      haltOnFailure: true, // never send an item ahead of its order
      onOutcome: (request, outcome) =>
          log('upload ${request.method} ${request.endpoint} ${outcome.name}'),
    ),
    onlineStream: onlineStream,
    replayOnStart: onlineStream != null,
    fetchSteps: [() => fetch('users/1'), () => fetch('todos/1')],
  );
}

/// Name the running app registers so a background task can find it.
const kSyncPort = 'fac.offline.syncNow';

/// Called by the running app, before it opens the queue: every background
/// task that fires while the app is alive gets the result of [run] instead of
/// opening the queue from a second isolate.
ReceivePort serveBackgroundSync(Future<bool> Function() run) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(kSyncPort); // stale after hot restart
  IsolateNameServer.registerPortWithName(port.sendPort, kSyncPort);
  port.listen((reply) async {
    var done = false;
    try {
      done = await run();
    } catch (_) {
      // Report "work left" so the OS tries again.
    }
    (reply as SendPort).send(done);
  });
  return port;
}

/// Called by the background task. `null` when no app is running, so the task
/// owns the queue. Otherwise it waits for the app's pass and returns whether
/// that finished everything: iOS suspends the app the moment the task
/// completes, so answering before the sync is done would cut it off.
///
/// [timeout] stays under the ~30 seconds iOS gives a refresh task.
Future<bool?> syncInRunningApp({
  Duration timeout = const Duration(seconds: 25),
}) async {
  final app = IsolateNameServer.lookupPortByName(kSyncPort);
  if (app == null) return null;
  final reply = ReceivePort();
  app.send(reply.sendPort);
  try {
    return await reply.first.timeout(timeout) as bool;
  } on TimeoutException {
    return false;
  } finally {
    reply.close();
  }
}
