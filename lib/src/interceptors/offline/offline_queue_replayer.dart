import 'dart:async';

import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/api_result.dart';
import '../../core/request_options.dart';
import '../internal_headers.dart';
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

/// Re-issues the pending mutations in an [OfflineQueueStore] through a live
/// [ApiClient].
///
/// Without this, [OfflineQueueInterceptor] enqueues failed writes that are
/// never sent. The replayer is the engine that actually delivers them — call
/// [replay] when connectivity returns (e.g. from a `connectivity_plus`
/// listener; this package does not bundle one to stay dependency-light).
///
/// Safety properties:
/// - Requests replay in priority-then-`createdAt` order (the stores sort on
///   read); pass [compare] to override the order entirely.
/// - Each request goes through `client`, so a fresh auth token is attached —
///   queued requests intentionally persist no `Authorization` header.
/// - Persisted query parameters and base-URL overrides are restored, so the
///   replay targets the same URL the original request did.
/// - A request that fails transiently is re-enqueued with an incremented
///   attempt count; once it reaches [maxAttempts] it is dead-lettered instead
///   of looping forever (poison-message protection).
/// - A request that reaches the server and is rejected (non network/timeout)
///   is dropped — replaying it would not help.
/// - Overlapping [replay] calls share one pass: a second call while a pass is
///   in flight returns the same future instead of double-sending the queue.
/// - When the store is a [PeekableOfflineQueueStore] (both built-in stores
///   are), requests stay persisted until each one is individually settled, so
///   a crash mid-replay cannot lose the not-yet-sent tail. Replay is
///   at-least-once by default: a crash after a send but before the matching
///   remove means that one request is resent on the next pass. A request
///   marked [ReplaySafety.atMostOnce] is instead removed *before* its send, so
///   an interruption drops it rather than duplicating a non-idempotent write.
///   Stores that only implement [OfflineQueueStore] use the legacy
///   destructive-drain path unchanged (already at-most-once for every
///   request).
class OfflineQueueReplayer {
  /// Creates a replayer that drains [store] through [client].
  OfflineQueueReplayer({
    required this.store,
    required this.client,
    this.maxAttempts = 3,
    this.onDeadLetter,
    this.compare,
    this.onOutcome,
  });

  /// Queue to drain and replay from.
  final OfflineQueueStore store;

  /// Live client each queued request is re-issued through.
  final ApiClient client;

  /// Maximum total replay attempts before a request is dead-lettered.
  final int maxAttempts;

  /// Called when a request is dropped without success, with the request and
  /// the error from its final attempt (`null` when the failure produced no
  /// [ApiException], e.g. re-persisting the request threw). Use it to tell
  /// the user a queued write was abandoned, or to forward it to your own
  /// dead-letter storage. Exceptions it throws are swallowed so a listener
  /// bug cannot abort the rest of the pass.
  final void Function(QueuedRequest request, ApiException? error)? onDeadLetter;

  /// Optional replay-order override. When `null`, the store's own read order is
  /// used (priority-desc, then oldest first — see `compareQueuedRequests`). When
  /// set, the pending batch is re-sorted with this comparator before replay, so
  /// callers can order by endpoint, method, custom header, or anything else.
  final Comparator<QueuedRequest>? compare;

  /// Optional per-request callback fired after each request's terminal outcome
  /// in a pass; awaited before moving to the next request. An optimistic layer
  /// uses it to commit or roll back local state ([OfflineMutations] wires this
  /// automatically). A throw aborts the remaining requests in the pass.
  final FutureOr<void> Function(QueuedRequest request, ReplayOutcome outcome)?
      onOutcome;

  Future<OfflineReplayReport>? _inFlight;

  /// Replays every pending request once, returning a report of how each one
  /// fared. Concurrent calls while a pass is running await that same pass.
  Future<OfflineReplayReport> replay() {
    final running = _inFlight;
    if (running != null) return running;
    final pass = _replayPass().whenComplete(() => _inFlight = null);
    _inFlight = pass;
    return pass;
  }

  Future<OfflineReplayReport> _replayPass() async {
    final s = store;
    final pending =
        s is PeekableOfflineQueueStore ? await s.peekAll() : await s.drain();
    if (compare != null) pending.sort(compare!);
    var succeeded = 0;
    var reEnqueued = 0;
    var deadLettered = 0;

    for (final request in pending) {
      // at-most-once: drop the record before the send so an interruption
      // between here and the response loses the request instead of resending
      // it. A transient failure below re-enqueues it, so the retry path is
      // unchanged — only the crash window differs.
      if (request.replaySafety == ReplaySafety.atMostOnce) {
        try {
          await _detach(request);
        } catch (_) {
          // Could not remove it up front, so the at-most-once guarantee cannot
          // be honoured for this request. Skipping is the only safe choice:
          // sending now risks the duplicate this mode exists to prevent.
          continue;
        }
      }
      bool isSuccess;
      bool transient;
      ApiException? error;
      try {
        final result = await _send(request);
        isSuccess = result.isSuccess;
        error = result.error;
        transient = error is NetworkError || error is TimeoutError;
      } catch (e) {
        // _send threw outside the ApiResult contract (e.g. an interceptor or
        // the client itself raised). Treat it as transient and keep the
        // request queued so a single unexpected failure cannot silently drop
        // it.
        isSuccess = false;
        transient = true;
        error = e is ApiException ? e : null;
      }

      if (isSuccess) {
        succeeded++;
        await _settle(request, keep: false);
        await onOutcome?.call(request, ReplayOutcome.succeeded);
        continue;
      }
      if (!transient) {
        deadLettered++;
        await _settle(request, keep: false);
        _notifyDeadLetter(request, error);
        await onOutcome?.call(request, ReplayOutcome.deadLettered);
        continue;
      }
      final next = request.withAttempt();
      // A transient failure is exactly the ambiguous case: the request may
      // have reached the server before the connection dropped. Retrying an
      // atMostOnce request would risk the duplicate the mode exists to
      // prevent, so it is dead-lettered instead — the caller is told the write
      // was abandoned rather than it being silently resent or silently lost.
      if (request.replaySafety == ReplaySafety.atMostOnce ||
          next.attempts >= maxAttempts) {
        deadLettered++;
        await _settle(request, keep: false);
        _notifyDeadLetter(request, error);
        await onOutcome?.call(request, ReplayOutcome.deadLettered);
      } else {
        // Persist defensively: if the store fails here we still want the
        // remaining pending requests to be processed, so swallow and count it.
        try {
          await _settle(next, keep: true);
          reEnqueued++;
          await onOutcome?.call(request, ReplayOutcome.reEnqueued);
        } catch (_) {
          deadLettered++;
          try {
            await _settle(request, keep: false);
          } catch (_) {
            // Peekable store failed to remove the record too; it will be
            // retried (and eventually dead-lettered) on a later pass.
          }
          _notifyDeadLetter(request, null);
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

  /// Settles [request] in the store after an attempt. With a peekable store
  /// the record is still persisted, so it is removed — and re-written with
  /// the bumped attempt count when [keep] is true. With a drain-based store
  /// the record is already gone; only kept requests are written back.
  Future<void> _settle(QueuedRequest request, {required bool keep}) async {
    // An atMostOnce request was already detached before its send, so there is
    // nothing left to remove; only a re-enqueue still has work to do.
    if (store is PeekableOfflineQueueStore &&
        request.replaySafety != ReplaySafety.atMostOnce) {
      await store.remove(request.id);
    }
    if (keep) {
      await store.enqueue(request);
    }
  }

  /// Removes [request] from a peekable store ahead of its send, implementing
  /// the [ReplaySafety.atMostOnce] guarantee. A drain-based store already
  /// removed it, so this is a no-op there.
  Future<void> _detach(QueuedRequest request) async {
    if (store is PeekableOfflineQueueStore) {
      await store.remove(request.id);
    }
  }

  void _notifyDeadLetter(QueuedRequest request, ApiException? error) {
    final cb = onDeadLetter;
    if (cb == null) return;
    try {
      cb(request, error);
    } catch (_) {
      // Listener errors must not abort the replay pass.
    }
  }

  Future<ApiResult<dynamic>> _send(QueuedRequest r) {
    final options = RequestOptions(
      // Mark the send as a replay so an OfflineQueueInterceptor on this same
      // client does not queue it again when it fails while still offline.
      // The replayer owns re-enqueueing (with the incremented attempt count);
      // double-queueing would grow the queue on every pass and reset the
      // attempt counter, so maxAttempts could never dead-letter the request.
      headers: {...r.headers, offlineReplayHeader: '1'},
      queryParameters: r.queryParameters,
      baseUrlOverride: r.baseUrlOverride,
    );
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
      case 'QUERY':
        return client.query<dynamic>(r.endpoint, r.body, options: options);
      default:
        return client.post<dynamic>(r.endpoint, r.body, options: options);
    }
  }
}
