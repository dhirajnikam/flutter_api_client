import 'package:flutter_api_client/flutter_api_client.dart';

/// The sync sequence, defined once and shared by the running app and the OS
/// background task: queued writes go out first (orders before their items),
/// then the fetches run in list order.
///
/// Plugin-free on purpose, so it runs in a test and in a background isolate.

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
