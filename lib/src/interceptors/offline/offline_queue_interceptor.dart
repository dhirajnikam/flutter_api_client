import '../../core/api_exception.dart';
import '../interceptor.dart';
import '../request_identity.dart';
import 'offline_queue.dart';

/// Detects network errors on mutating requests and stores them for replay.
class OfflineQueueInterceptor extends Interceptor {
  /// Creates an interceptor that queues failed mutations into [store].
  OfflineQueueInterceptor({
    required this.store,
    this.methods = const {'POST', 'PUT', 'PATCH', 'DELETE'},
    this.isOnline,
    this.onQueued,
    this.priorityOf,
  });

  /// Backend the failed mutations are queued into.
  final OfflineQueueStore store;

  /// Mutating methods eligible for queuing (compared case-insensitively).
  final Set<String> methods;

  /// Optional connectivity probe. When it reports online, errors are not
  /// queued (they are genuine failures, not offline conditions). When `null`,
  /// the request is always treated as offline on a network/timeout error.
  final Future<bool> Function()? isOnline;

  /// Called after a request has been queued, with the stored record. Use it
  /// to surface "saved offline, will sync" UI or to schedule an
  /// `OfflineQueueReplayer.replay` pass when connectivity returns. Exceptions
  /// it throws are swallowed so a listener bug cannot mask the original
  /// network error.
  final void Function(QueuedRequest request)? onQueued;

  /// Optional per-request replay priority. Returns the [QueuedRequest.priority]
  /// to store for [req]; higher replays first. Defaults to `0` for every
  /// request when `null`. Use it to prioritise, say, DELETEs over POSTs, or
  /// requests to a critical endpoint.
  final int Function(InterceptedRequest req)? priorityOf;

  /// Monotonic per-instance sequence appended to each id. Two mutations to the
  /// same endpoint inside one microsecond (or whose `endpoint.hashCode`
  /// collides) would otherwise mint identical ids, and a keyed persistent
  /// store ([HiveOfflineQueueStore] uses `box.put(id, ...)`) would silently
  /// overwrite the first — losing a write. The counter guarantees uniqueness
  /// regardless of clock resolution or hash collisions.
  int _seq = 0;

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    if (!methods.contains(req.method.toUpperCase())) return RejectResult(error);
    if (error is! NetworkError && error is! TimeoutError) {
      return RejectResult(error);
    }
    // Multipart payloads (streams/files) cannot be serialized into the queue
    // or faithfully replayed later, so they are never queued.
    if (req.isMultipart) return RejectResult(error);
    final online = isOnline == null ? false : await isOnline!();
    if (online) return RejectResult(error);
    final now = DateTime.now();
    final id =
        '${now.microsecondsSinceEpoch}-${_seq++}-${req.endpoint.hashCode}';
    final queued = QueuedRequest(
      id: id,
      method: req.method,
      endpoint: req.endpoint,
      headers: _queuedHeaders(req.headers),
      body: req.data,
      createdAt: now,
      queryParameters: req.options.queryParameters,
      baseUrlOverride: req.options.baseUrlOverride,
      priority: priorityOf?.call(req) ?? 0,
    );
    // Never let a queueing failure mask the network error the caller needs to
    // see: if the store throws (e.g. a persistent store cannot JSON-encode
    // the body, or the disk write fails), the request is simply not queued
    // and the original error still propagates.
    try {
      await store.enqueue(queued);
    } catch (_) {
      return RejectResult(error);
    }
    if (onQueued != null) {
      try {
        onQueued!(queued);
      } catch (_) {
        // Listener errors must not replace the original network error.
      }
    }
    return RejectResult(error);
  }

  Map<String, String> _queuedHeaders(Map<String, String> headers) {
    final queued = stripInternalRequestHeaders(headers);
    queued.removeWhere((name, _) => name.toLowerCase() == 'authorization');
    return queued;
  }
}
