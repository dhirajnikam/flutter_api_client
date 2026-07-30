import '../core/query.dart';
import 'interceptor.dart';

const Set<String> _internalRequestHeaders = {
  'x-fac-cache-revalidate',
  'x-fac-dedup-key',
  'x-fac-retried-auth',
  'x-fac-auth-token-fp',
  'x-fac-retry-attempt',
};

/// Whether [name] is one of the `x-fac-*` headers the interceptors use
/// internally for coordination and must never be sent to the origin or used
/// as part of a request's identity. Matched case-insensitively.
bool isInternalRequestHeader(String name) =>
    _internalRequestHeaders.contains(name.toLowerCase());

/// Returns a copy of [headers] with every internal `x-fac-*` header removed.
Map<String, String> stripInternalRequestHeaders(Map<String, String> headers) {
  final out = <String, String>{};
  for (final entry in headers.entries) {
    if (isInternalRequestHeader(entry.key)) continue;
    out[entry.key] = entry.value;
  }
  return out;
}

/// Stable identity key for a request, used to match cache entries and to
/// coalesce duplicate in-flight requests.
///
/// Built from the method, the fully-resolved URL (base + endpoint + query),
/// and the request headers sorted by name. `If-None-Match` and the internal
/// `x-fac-*` headers are excluded so that a conditional revalidation request
/// keys to the same entry as the original.
///
/// The `Authorization` header is deliberately part of the key: cached bodies
/// must never leak across credentials, so a token refresh cold-starts the
/// cache and stops dedup coalescing across the refresh boundary. That
/// re-fetch cost is the accepted price of credential isolation.
String requestIdentityKey(InterceptedRequest req) {
  final url = buildUri(
    baseUrl: req.options.baseUrlOverride ?? '',
    endpoint: req.endpoint,
    queryParameters: req.options.queryParameters,
  ).toString();

  // Decorate-sort: lowercase each surviving header name exactly once, reusing
  // that value for both the sort key and the emitted line. The previous form
  // re-lowercased inside the comparator (O(n log n) lowercasings) and again
  // in the emit loop (another O(n)); this is a single O(n) pass. Output is
  // byte-for-byte identical — sort order and emitted key/value are unchanged.
  final entries = <_HeaderLine>[];
  for (final entry in req.headers.entries) {
    final lower = entry.key.toLowerCase();
    if (lower == 'if-none-match' || isInternalRequestHeader(lower)) continue;
    entries.add(_HeaderLine(lower, entry.value));
  }

  final prefix = '${req.method.toUpperCase()} $url';
  if (entries.isEmpty) return prefix;

  entries.sort((a, b) => a.lowerKey.compareTo(b.lowerKey));

  final buffer = StringBuffer(prefix);
  for (final entry in entries) {
    buffer
      ..write('\n')
      ..write(entry.lowerKey)
      ..write(':')
      ..write(entry.value);
  }
  return buffer.toString();
}

/// A header reduced to its lowercased name and original value, computed once
/// so the identity-key build never re-lowercases the same name.
class _HeaderLine {
  _HeaderLine(this.lowerKey, this.value);

  final String lowerKey;
  final String value;
}
