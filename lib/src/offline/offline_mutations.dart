import '../client/api_client.dart';
import '../core/error_classification.dart';
import '../core/api_result.dart';
import '../core/request_options.dart';
import 'offline_queue.dart';
import 'offline_queue_replayer.dart';
import 'queued_request_factory.dart';

/// Optimistic offline mutations with pluggable local-data callbacks.
///
/// This is the front door for "modify local data now, sync the API call later".
/// Call [mutate] instead of `client.post`/`put`/`patch`/`delete` for any write
/// you want to survive being offline:
///
/// 1. `apply` runs immediately, so your local store (and UI) update at once.
/// 2. The request is sent through [client]. On success, done.
/// 3. If it fails because the device is offline (a `NetworkError`/`TimeoutError`),
///    the request is enqueued into [store] for later replay and the optimistic
///    state is kept.
/// 4. If the server was reached and rejected the write (any non-transient
///    error), `rollback` runs and the optimistic state is undone.
///
/// When connectivity returns, drive an [OfflineQueueReplayer] (see
/// [buildReplayer]). On a queued request's terminal outcome the manager commits
/// (drops the rollback) on success or runs `rollback` on dead-letter.
///
/// The package stays model-agnostic: it never touches your data directly, it
/// just calls the `apply`/`rollback` closures you supply, so it works with Hive,
/// Isar, Drift, a Bloc, a Riverpod notifier, or a plain in-memory map.
///
/// ponytail: `rollback` closures live in memory, keyed by request id. A request
/// that is queued, then the app restarts, then dead-letters on the next run has
/// no rollback to call (the closure is gone) — the queued write is dropped but
/// local state is not reverted. Persisting rollbacks would mean serialising
/// closures, which Dart can't do; if you need restart-durable rollback, make
/// `apply` write a "pending" marker your own code reconciles on startup.
class OfflineMutations {
  OfflineMutations({required this.client, required this.store});

  /// Client each mutation is attempted (and later replayed) through.
  final ApiClient client;

  /// Queue failed mutations are persisted into for later replay.
  final OfflineQueueStore store;

  /// In-memory rollback closures, keyed by [QueuedRequest.id]. See the
  /// class-level ponytail note on why these are not persisted.
  final Map<String, Future<void> Function()> _rollbacks = {};

  /// Applies [apply] optimistically, sends the mutation, and queues it for
  /// replay if the device is offline.
  ///
  /// [method] is one of `POST`/`PUT`/`PATCH`/`DELETE` (case-insensitive).
  /// [priority] sets the replay [QueuedRequest.priority] (higher replays first).
  /// [replaySafety] sets the delivery guarantee: the default
  /// [ReplaySafety.atLeastOnce] may resend a request whose send was interrupted,
  /// so pass [ReplaySafety.atMostOnce] for a non-idempotent create where a
  /// duplicate record is worse than a dropped one. An `atMostOnce` mutation
  /// whose transient failure is ambiguous is dead-lettered, which runs
  /// [rollback]; one rejected before it was sent (open circuit) stays queued.
  /// [rollback] is run if the write is rejected by the server now, or if it is
  /// dead-lettered during replay later.
  ///
  /// Returns the underlying [ApiResult]: `Success` when it went through, or a
  /// `Failure` carrying `NetworkError`/`TimeoutError` when it was queued.
  Future<ApiResult<T>> mutate<T>(
    String method,
    String endpoint,
    Object? body, {
    int priority = 0,
    ReplaySafety replaySafety = ReplaySafety.atLeastOnce,
    Future<void> Function()? apply,
    Future<void> Function()? rollback,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) async {
    if (apply != null) await apply();

    final verb = method.toUpperCase();
    if (!offlineWriteMethods.contains(verb)) {
      throw ArgumentError.value(
        method,
        'method',
        'OfflineMutations supports POST, PUT, PATCH, DELETE',
      );
    }
    final result = await client.request<T>(
      verb,
      endpoint,
      data: sendableBody(verb, body),
      options: options,
      decoder: decoder,
    );
    if (result.isSuccess) return result;

    final error = (result as Failure<T>).error;
    if (!error.isTransient) {
      // The server was reached and rejected the write; replaying would not help,
      // so undo the optimistic change immediately.
      if (rollback != null) await rollback();
      return result;
    }

    final queued = newQueuedRequest(
      method: verb,
      endpoint: endpoint,
      headers: options?.headers ?? const {},
      includeToken: options?.includeToken ?? true,
      body: body,
      queryParameters: options?.queryParameters,
      baseUrlOverride: options?.baseUrlOverride,
      priority: priority,
      replaySafety: replaySafety,
    );
    if (rollback != null) _rollbacks[queued.id] = rollback;
    await store.enqueue(queued);
    return result;
  }

  /// Wire this into an [OfflineQueueReplayer.onOutcome] to commit or roll back
  /// optimistic state as each queued request is replayed. [buildReplayer] does
  /// this for you; use this directly only if you construct the replayer yourself.
  Future<void> handleOutcome(
    QueuedRequest request,
    ReplayOutcome outcome,
  ) async {
    switch (outcome) {
      case ReplayOutcome.succeeded:
        _rollbacks.remove(request.id);
      case ReplayOutcome.deadLettered:
        final rollback = _rollbacks.remove(request.id);
        if (rollback != null) await rollback();
      case ReplayOutcome.reEnqueued:
        // Still pending a future pass — keep the rollback registered.
        break;
    }
  }

  /// Builds an [OfflineQueueReplayer] already wired to this manager's
  /// [handleOutcome], so replaying commits/rolls back optimistic state for you.
  OfflineQueueReplayer buildReplayer({
    int maxAttempts = 3,
    Comparator<QueuedRequest>? compare,
    Duration? neverSentMaxAge,
  }) =>
      OfflineQueueReplayer(
        store: store,
        client: client,
        maxAttempts: maxAttempts,
        compare: compare,
        neverSentMaxAge: neverSentMaxAge,
        onOutcome: handleOutcome,
      );
}
