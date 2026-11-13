import 'dart:async';

import '../client/api_client.dart';
import '../core/api_exception.dart';
import '../core/error_classification.dart';
import '../core/api_result.dart';
import '../core/request_options.dart';
import 'offline_queue.dart';
import 'queued_request_factory.dart';

/// What happened to a single request during a replay pass.
enum ReplayOutcome {
  /// Replayed successfully and dropped from the queue.
  succeeded,

  /// Failed transiently and put back for a later pass. A failure that never
  /// sent the request (`NetworkError.sent == false`) does not count against
  /// `maxAttempts`.
  reEnqueued,

  /// Dropped without success — the server rejected it (non-transient), it
  /// exhausted `maxAttempts`, or it is an `atMostOnce` request whose transient
  /// failure was ambiguous (it may have reached the server, so it is not
  /// resent). This is the terminal failure an optimistic layer should roll back
  /// on.
  deadLettered,
}

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
  /// Requests rejected before being sent (e.g. by an open circuit) are counted
  /// here too, without using up an attempt.
  final int reEnqueued;

  /// Requests dropped without success: a non-transient failure (the server was
  /// reached and rejected them), requests that exhausted `maxAttempts`, or
  /// `atMostOnce` requests whose transient failure was ambiguous.
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
///   of looping forever (poison-message protection). A failure that provably
///   never sent the request (`NetworkError.sent == false`, e.g. an open circuit)
///   is re-enqueued without consuming an attempt, in either mode. Set
///   [neverSentMaxAge] to dead-letter such a request once it has been queued
///   that long, so a host that stays down cannot hold it forever.
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
///   Stores that only implement [OfflineQueueStore] use the
///   destructive-drain path (at-most-once for every request).
class OfflineQueueReplayer {
  OfflineQueueReplayer({
    required this.store,
    required this.client,
    this.maxAttempts = 3,
    this.onDeadLetter,
    this.compare,
    this.onOutcome,
    this.neverSentMaxAge,
  }) : assert(
          neverSentMaxAge == null || neverSentMaxAge >= Duration.zero,
          'neverSentMaxAge must not be negative',
        );

  final OfflineQueueStore store;

  /// Live client each queued request is re-issued through.
  final ApiClient client;

  /// Maximum total replay attempts before a request is dead-lettered.
  final int maxAttempts;

  /// How long (since [QueuedRequest.createdAt]) a request that keeps failing
  /// without being sent (`NetworkError.sent == false`) stays queued before it
  /// is dead-lettered. Such failures do not consume [maxAttempts], so without
  /// this a write to a host whose circuit keeps reopening is kept forever.
  /// `null` (the default) keeps it until a request gets through;
  /// [Duration.zero] dead-letters it on its first never-sent failure.
  final Duration? neverSentMaxAge;

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
    // A peekable store keeps every record until it is removed; a drain-only
    // store has already handed them all over.
    final persisted = s is PeekableOfflineQueueStore;
    final pending = persisted ? await s.peekAll() : await s.drain();
    if (compare != null) pending.sort(compare!);
    var succeeded = 0;
    var reEnqueued = 0;
    var deadLettered = 0;

    for (final request in pending) {
      final atMostOnce = request.replaySafety == ReplaySafety.atMostOnce;
      var stored = persisted;
      Future<void> remove() async {
        if (!stored) return;
        await store.remove(request.id);
        stored = false;
      }

      Future<void> deadLetter(ApiException? error) async {
        deadLettered++;
        await remove();
        _notifyDeadLetter(request, error);
        await onOutcome?.call(request, ReplayOutcome.deadLettered);
      }

      // at-most-once: drop the record before the send so an interruption
      // between here and the response loses the request instead of resending
      // it. A failure that provably never sent it re-enqueues it below; any
      // other transient failure dead-letters it.
      if (atMostOnce) {
        try {
          await remove();
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
        transient = error?.isTransient ?? false;
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
        await remove();
        await onOutcome?.call(request, ReplayOutcome.succeeded);
        continue;
      }
      if (!transient) {
        await deadLetter(error);
        continue;
      }
      // A failure that definitely never left the device (e.g. an open circuit
      // breaker) is safe to retry in either mode and says nothing about the
      // request itself, so it does not consume an attempt.
      final neverSent = error?.neverSent ?? false;
      final next = neverSent ? request : request.withAttempt();
      final maxAge = neverSentMaxAge;
      final expired = neverSent &&
          maxAge != null &&
          DateTime.now().difference(request.createdAt) >= maxAge;
      // Any other transient failure is ambiguous: the request may have reached
      // the server before the connection dropped. Retrying an atMostOnce
      // request would risk the duplicate the mode exists to prevent, so it is
      // dead-lettered instead — the caller is told the write was abandoned
      // rather than it being silently resent or silently lost.
      if ((atMostOnce && !neverSent) ||
          next.attempts >= maxAttempts ||
          expired) {
        await deadLetter(error);
        continue;
      }
      try {
        await remove();
        await store.enqueue(next);
      } catch (_) {
        // The store could not re-persist it. Count it and carry on so the
        // remaining requests are still processed. A failed write may still
        // have left a record behind, so remove again.
        stored = persisted && !atMostOnce;
        try {
          await remove();
        } catch (_) {
          // The record is still stored; a later pass retries (and eventually
          // dead-letters) it.
          stored = false;
        }
        await deadLetter(null);
        continue;
      }
      reEnqueued++;
      await onOutcome?.call(request, ReplayOutcome.reEnqueued);
    }

    return OfflineReplayReport(
      succeeded: succeeded,
      reEnqueued: reEnqueued,
      deadLettered: deadLettered,
    );
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

  Future<ApiResult<dynamic>> _send(QueuedRequest r) => client.request<dynamic>(
        r.method,
        r.endpoint,
        data: sendableBody(r.method, r.body),
        options: RequestOptions(
          headers: {...r.headers, offlineReplayHeader: '1'},
          queryParameters: r.queryParameters,
          baseUrlOverride: r.baseUrlOverride,
          includeToken: r.includeToken,
        ),
      );
}
