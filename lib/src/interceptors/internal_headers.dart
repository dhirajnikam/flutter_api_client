/// Response header the cache interceptor uses to mark responses it fabricated
/// itself: `hit` for a body served from the store, `miss` for the synthetic
/// 504 a `cacheOnly` miss resolves with. Internal coordination only — never
/// sent to the origin.
const String cacheHitHeader = 'x-fac-cache-hit';

/// Marker value for a response whose body was served from the cache store.
const String cacheHitValue = 'hit';

/// Marker value for the synthetic 504 fabricated on a `cacheOnly` miss.
const String cacheMissValue = 'miss';

/// Request header `OfflineQueueReplayer` sets on every request it re-issues,
/// so `OfflineQueueInterceptor` can tell a replay apart from a fresh call and
/// decline to queue it a second time.
///
/// Without it, replaying through a client that still has the offline
/// interceptor attached (the wiring the README recommends, since the replay
/// needs the same auth and base URL) re-queues every request that fails while
/// still offline: the queue doubles on each pass and the duplicates carry a
/// reset attempt count, so `maxAttempts` never dead-letters them. The replayer
/// owns re-enqueueing — it re-persists with an incremented attempt count
/// itself — so the interceptor must stay out of the way. Internal coordination
/// only; stripped before the request reaches the origin.
const String offlineReplayHeader = 'x-fac-offline-replay';

/// Case-insensitive lookup of [name] in [headers]. HTTP header names are
/// case-insensitive (RFC 7230 §3.2) and adapters are not required to
/// normalize them, so header reads must not assume a particular casing.
String? headerValue(Map<String, String> headers, String name) {
  final direct = headers[name];
  if (direct != null) return direct;
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}
