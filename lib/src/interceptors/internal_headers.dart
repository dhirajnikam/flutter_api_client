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

/// Parses a `Retry-After` header per RFC 7231: either delta-seconds or an
/// IMF-fixdate. Returns null for a missing, negative, or unparseable value so
/// callers fall back to their own delay policy. Shared by the retry policy
/// and the rate limiter so both interpret the header identically.
Duration? parseRetryAfter(Map<String, String> headers) {
  final ra = headerValue(headers, 'retry-after')?.trim();
  if (ra == null || ra.isEmpty) return null;
  final secs = int.tryParse(ra);
  if (secs != null) return secs < 0 ? null : Duration(seconds: secs);
  final date = _tryParseHttpDate(ra);
  if (date == null) return null;
  final delta = date.difference(DateTime.now());
  return delta.isNegative ? Duration.zero : delta;
}

/// Minimal IMF-fixdate parser (e.g. `Sun, 06 Nov 1994 08:49:37 GMT`).
/// Avoids `dart:io`'s `HttpDate` so the package stays web-compatible.
DateTime? _tryParseHttpDate(String value) {
  const months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final m = RegExp(
    r'^[A-Za-z]+, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value);
  if (m == null) return null;
  final month = months[m.group(2)];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}
