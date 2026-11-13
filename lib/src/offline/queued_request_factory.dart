import '../interceptors/internal_headers.dart';
import 'offline_queue.dart';

/// The writes the offline queue handles unless told otherwise.
const Set<String> offlineWriteMethods = {'POST', 'PUT', 'PATCH', 'DELETE'};

/// The body to send for a queued [method]. `ApiClient.get` and
/// `ApiClient.delete` take no body, so a queued one is never sent with any.
Object? sendableBody(String method, Object? body) =>
    const {'GET', 'DELETE'}.contains(method.toUpperCase()) ? null : body;

int _seq = 0;

/// Builds the record persisted for a write that could not be sent.
///
/// The credential header is never persisted (a replay attaches a fresh
/// token), and neither are internal coordination headers.
QueuedRequest newQueuedRequest({
  required String method,
  required String endpoint,
  required Map<String, String> headers,
  bool Function(String name)? isCredential,
  bool includeToken = true,
  required Object? body,
  required Map<String, dynamic>? queryParameters,
  required String? baseUrlOverride,
  required int priority,
  required ReplaySafety replaySafety,
}) {
  final now = DateTime.now();
  return QueuedRequest(
    // The sequence keeps ids unique when two writes to the same endpoint land
    // in the same microsecond (or their `endpoint.hashCode`s collide); a keyed
    // persistent store would otherwise silently overwrite the first.
    id: '${now.microsecondsSinceEpoch}-${_seq++}-${endpoint.hashCode}',
    method: method,
    endpoint: endpoint,
    headers: stripInternalHeaders(headers)
      ..removeWhere(
        (name, _) =>
            name.toLowerCase() == 'authorization' ||
            (isCredential?.call(name) ?? false),
      ),
    body: body,
    createdAt: now,
    queryParameters: queryParameters,
    baseUrlOverride: baseUrlOverride,
    priority: priority,
    replaySafety: replaySafety,
    includeToken: includeToken,
  );
}

/// Request header `OfflineQueueReplayer` sets on every request it re-issues,
/// so `OfflineQueueInterceptor` can tell a replay apart from a fresh call and
/// decline to queue it a second time.
///
/// Without it, replaying through a client that still has the offline
/// interceptor attached (the wiring the README recommends, since the replay
/// needs the same auth and base URL) re-queues every request that fails while
/// still offline: the queue doubles on each pass and the duplicates carry a
/// reset attempt count, so `maxAttempts` never dead-letters them. The replayer
/// owns re-enqueueing, so the interceptor must stay out of the way.
///
/// It is a header rather than interceptor state because the replayer only has
/// the public client API to send through.
const String offlineReplayHeader = 'x-fac-offline-replay';
