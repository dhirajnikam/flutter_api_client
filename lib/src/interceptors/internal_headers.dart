/// Response header the cache interceptor uses to mark responses it fabricated
/// itself: `hit` for a body served from the store, `miss` for the synthetic
/// 504 a `cacheOnly` miss resolves with. Internal coordination only — never
/// sent to the origin.
const String cacheHitHeader = 'x-fac-cache-hit';

/// Marker value for a response whose body was served from the cache store.
const String cacheHitValue = 'hit';

/// Marker value for the synthetic 504 fabricated on a `cacheOnly` miss.
const String cacheMissValue = 'miss';

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
