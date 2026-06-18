import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/api_result.dart';
import '../../core/request_options.dart';
import 'offline_queue.dart';

/// Outcome of an [OfflineQueueReplayer.replay] pass.
class OfflineReplayReport {
  const OfflineReplayReport({
    this.succeeded = 0,
    this.reEnqueued = 0,
    this.deadLettered = 0,
  });

  /// Requests that replayed successfully and were dropped from the queue.
  final int succeeded;

  /// Requests that failed transiently (network/timeout) and were put back.
  final int reEnqueued;

  /// Requests dropped without success: either a non-transient failure
  /// (the server was reached and rejected them) or they exhausted
  /// `maxAttempts`.
  final int deadLettered;

  int get total => succeeded + reEnqueued + deadLettered;

  @override
  String toString() =>
      'OfflineReplayReport(succeeded: $succeeded, reEnqueued: $reEnqueued, '
      'deadLettered: $deadLettered)';
}

/// Drains an [OfflineQueueStore] and re-issues each pending mutation through a
/// live [ApiClient].
///
/// Without this, [OfflineQueueInterceptor] enqueues failed writes that are
/// never sent. The replayer is the engine that actually delivers them — call
/// [replay] when connectivity returns (e.g. from a `connectivity_plus`
/// listener; this package does not bundle one to stay dependency-light).
///
/// Safety properties:
/// - Requests replay in `createdAt` order (the stores sort on drain).
/// - Each request goes through `client`, so a fresh auth token is attached —
///   queued requests intentionally persist no `Authorization` header.
/// - A request that fails transiently is re-enqueued with an incremented
///   attempt count; once it reaches [maxAttempts] it is dead-lettered instead
///   of looping forever (poison-message protection).
/// - A request that reaches the server and is rejected (non network/timeout)
///   is dropped — replaying it would not help.
///
/// Note: [OfflineQueueStore.drain] is destructive, so a crash mid-replay can
/// drop the requests already drained but not yet resent. A crash-safe
/// non-destructive drain is a future improvement.
class OfflineQueueReplayer {
  OfflineQueueReplayer({
    required this.store,
    required this.client,
    this.maxAttempts = 3,
  });

  final OfflineQueueStore store;
  final ApiClient client;

  /// Maximum total replay attempts before a request is dead-lettered.
  final int maxAttempts;

  Future<OfflineReplayReport> replay() async {
    final pending = await store.drain();
    var succeeded = 0;
    var reEnqueued = 0;
    var deadLettered = 0;

    for (final request in pending) {
      bool isSuccess;
      bool transient;
      try {
        final result = await _send(request);
        isSuccess = result.isSuccess;
        final error = result.error;
        transient = error is NetworkError || error is TimeoutError;
      } catch (e) {
        // _send threw outside the ApiResult contract (e.g. an interceptor or
        // the client itself raised). Treat it as transient and re-enqueue so a
        // single unexpected failure cannot abort the loop and silently drop
        // every request already drained from the (destructive) store.
        isSuccess = false;
        transient = true;
      }

      if (isSuccess) {
        succeeded++;
        continue;
      }
      if (!transient) {
        deadLettered++;
        continue;
      }
      final next = request.withAttempt();
      if (next.attempts >= maxAttempts) {
        deadLettered++;
      } else {
        // Re-enqueue defensively: if persistence itself fails we still want the
        // remaining pending requests to be processed, so swallow and count it.
        try {
          await store.enqueue(next);
          reEnqueued++;
        } catch (_) {
          deadLettered++;
        }
      }
    }

    return OfflineReplayReport(
      succeeded: succeeded,
      reEnqueued: reEnqueued,
      deadLettered: deadLettered,
    );
  }

  Future<ApiResult<dynamic>> _send(QueuedRequest r) {
    final options = RequestOptions(headers: r.headers);
    switch (r.method.toUpperCase()) {
      case 'POST':
        return client.post<dynamic>(r.endpoint, r.body, options: options);
      case 'PUT':
        return client.put<dynamic>(r.endpoint, r.body, options: options);
      case 'PATCH':
        return client.patch<dynamic>(r.endpoint, r.body, options: options);
      case 'DELETE':
        return client.delete<dynamic>(r.endpoint, options: options);
      case 'GET':
        return client.get<dynamic>(r.endpoint, options: options);
      default:
        return client.post<dynamic>(r.endpoint, r.body, options: options);
    }
  }
}
