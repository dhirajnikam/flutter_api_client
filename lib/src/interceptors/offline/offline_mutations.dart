import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/api_result.dart';
import '../../core/request_options.dart';
import '../request_identity.dart';
import 'offline_queue.dart';
import 'offline_queue_replayer.dart';

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
  /// Creates a manager that sends through [client] and queues into [store].
  OfflineMutations({required this.client, required this.store});

  /// Client each mutation is attempted (and later replayed) through.
  final ApiClient client;

  /// Queue failed mutations are persisted into for later replay.
  final OfflineQueueStore store;

  /// In-memory rollback closures, keyed by [QueuedRequest.id]. See the
  /// class-level ponytail note on why these are not persisted.
  final Map<String, Future<void> Function()> _rollbacks = {};

  /// Monotonic per-instance sequence, mirroring [OfflineQueueInterceptor], so
  /// two mutations minted in the same microsecond get distinct ids and a keyed
  /// store cannot silently overwrite one with the other.
  int _seq = 0;

  /// Applies [apply] optimistically, sends the mutation, and queues it for
  /// replay if the device is offline.
  ///
  /// [method] is one of `POST`/`PUT`/`PATCH`/`DELETE` (case-insensitive).
  /// [priority] sets the replay [QueuedRequest.priority] (higher replays first).
  /// [replaySafety] sets the delivery guarantee: the default
  /// [ReplaySafety.atLeastOnce] may resend a request whose send was interrupted,
  /// so pass [ReplaySafety.atMostOnce] for a non-idempotent create where a
  /// duplicate record is worse than a dropped one. An `atMostOnce` mutation that
  /// cannot be delivered is dead-lettered, which runs [rollback].
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

    final result = await _send<T>(method, endpoint, body, options, decoder);
    if (result.isSuccess) return result;

    final error = (result as Failure<T>).error;
    final offline = error is NetworkError || error is TimeoutError;
    if (!offline) {
      // The server was reached and rejected the write; replaying would not help,
      // so undo the optimistic change immediately.
      if (rollback != null) await rollback();
      return result;
    }

    final now = DateTime.now();
    final id = '${now.microsecondsSinceEpoch}-${_seq++}-${endpoint.hashCode}';
    if (rollback != null) _rollbacks[id] = rollback;
    await store.enqueue(
      QueuedRequest(
        id: id,
        method: method.toUpperCase(),
        endpoint: endpoint,
        headers: _queuedHeaders(options?.headers),
        body: body,
        createdAt: now,
        priority: priority,
        replaySafety: replaySafety,
      ),
    );
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
  }) =>
      OfflineQueueReplayer(
        store: store,
        client: client,
        maxAttempts: maxAttempts,
        compare: compare,
        onOutcome: handleOutcome,
      );

  Future<ApiResult<T>> _send<T>(
    String method,
    String endpoint,
    Object? body,
    RequestOptions? options,
    T Function(Object json)? decoder,
  ) {
    switch (method.toUpperCase()) {
      case 'POST':
        return client.post<T>(endpoint, body,
            options: options, decoder: decoder);
      case 'PUT':
        return client.put<T>(endpoint, body,
            options: options, decoder: decoder);
      case 'PATCH':
        return client.patch<T>(endpoint, body,
            options: options, decoder: decoder);
      case 'DELETE':
        return client.delete<T>(endpoint, options: options, decoder: decoder);
      default:
        throw ArgumentError.value(
          method,
          'method',
          'OfflineMutations supports POST, PUT, PATCH, DELETE',
        );
    }
  }

  /// Mirrors [OfflineQueueInterceptor]: the `Authorization` header is never
  /// persisted (the replayer attaches a fresh token), and internal `x-fac-*`
  /// coordination headers are stripped.
  Map<String, String> _queuedHeaders(Map<String, String>? headers) {
    final queued = stripInternalRequestHeaders(headers ?? const {});
    queued.removeWhere((name, _) => name.toLowerCase() == 'authorization');
    return queued;
  }
}
