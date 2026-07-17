import 'dart:async';

import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/api_result.dart';
import '../../core/request_options.dart';
import 'offline_queue.dart';

/// What happened to a single request during a replay pass.
enum ReplayOutcome {
  /// Replayed successfully and dropped from the queue.
  succeeded,

  /// Failed transiently and put back for a later pass.
  reEnqueued,

  /// Dropped without success — either the server rejected it (non-transient) or
  /// it exhausted `maxAttempts`. This is the terminal failure an optimistic
  /// layer should roll back on.
  deadLettered,
}

/// Outcome of an [OfflineQueueReplayer.replay] pass.
class OfflineReplayReport {
  /// Creates a report; all counts default to zero.
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

  /// Total requests processed in the pass.
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
/// - Requests replay in priority-then-`createdAt` order (the stores sort on
///   drain); pass [compare] to override the order entirely.
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
  /// Creates a replayer that drains [store] through [client].
  OfflineQueueReplayer({
    required this.store,
    required this.client,
    this.maxAttempts = 3,
    this.compare,
    this.onOutcome,
  });

  /// Queue to drain and replay from.
  final OfflineQueueStore store;

  /// Live client each queued request is re-issued through.
  final ApiClient client;

  /// Maximum total replay attempts before a request is dead-lettered.
  final int maxAttempts;

  /// Optional replay-order override. When `null`, the store's own drain order is
  /// used (priority-desc, then oldest first — see `compareQueuedRequests`). When
  /// set, the drained batch is re-sorted with this comparator before replay, so
  /// callers can order by endpoint, method, custom header, or anything else.
  final Comparator<QueuedRequest>? compare;

  /// Optional per-request callback fired after each request's terminal outcome
  /// in a pass; awaited before moving to the next request. An optimistic layer
  /// uses it to commit or roll back local state ([OfflineMutations] wires this
  /// automatically). A throw aborts the remaining requests in the pass.
  final FutureOr<void> Function(QueuedRequest request, ReplayOutcome outcome)?
      onOutcome;

  /// Drains the queue and replays every pending request once, returning a
  /// report of how each one fared.
  Future<OfflineReplayReport> replay() async {
    final pending = await store.drain();
    if (compare != null) pending.sort(compare!);
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
        await onOutcome?.call(request, ReplayOutcome.succeeded);
        continue;
      }
      if (!transient) {
        deadLettered++;
        await onOutcome?.call(request, ReplayOutcome.deadLettered);
        continue;
      }
      final next = request.withAttempt();
      if (next.attempts >= maxAttempts) {
        deadLettered++;
        await onOutcome?.call(request, ReplayOutcome.deadLettered);
      } else {
        // Re-enqueue defensively: if persistence itself fails we still want the
        // remaining pending requests to be processed, so swallow and count it.
        try {
          await store.enqueue(next);
          reEnqueued++;
          await onOutcome?.call(request, ReplayOutcome.reEnqueued);
        } catch (_) {
          deadLettered++;
          await onOutcome?.call(request, ReplayOutcome.deadLettered);
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
