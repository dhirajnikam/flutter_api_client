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
    await store.enqueue(
      QueuedRequest(
        id: '${DateTime.now().microsecondsSinceEpoch}-${req.endpoint.hashCode}',
        method: req.method,
        endpoint: req.endpoint,
        headers: _queuedHeaders(req.headers),
        body: req.data,
        createdAt: DateTime.now(),
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
