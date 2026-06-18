import '../../core/api_exception.dart';
import '../interceptor.dart';
import '../request_identity.dart';
import 'offline_queue.dart';

/// Detects network errors on mutating requests and stores them for replay.
class OfflineQueueInterceptor extends Interceptor {
  OfflineQueueInterceptor({
    required this.store,
    this.methods = const {'POST', 'PUT', 'PATCH', 'DELETE'},
    this.isOnline,
  });

  final OfflineQueueStore store;
  final Set<String> methods;
  final Future<bool> Function()? isOnline;

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
    final online = isOnline == null ? false : await isOnline!();
    if (online) return RejectResult(error);
    final now = DateTime.now();
    final id =
        '${now.microsecondsSinceEpoch}-${_seq++}-${req.endpoint.hashCode}';
    await store.enqueue(
      QueuedRequest(
        id: id,
        method: req.method,
        endpoint: req.endpoint,
        headers: _queuedHeaders(req.headers),
        body: req.data,
        createdAt: now,
      ),
    );
    return RejectResult(error);
  }

  Map<String, String> _queuedHeaders(Map<String, String> headers) {
    final queued = stripInternalRequestHeaders(headers);
    queued.removeWhere((name, _) => name.toLowerCase() == 'authorization');
    return queued;
  }
}
