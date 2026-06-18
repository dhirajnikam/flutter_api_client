import 'dart:math';

import '../../core/api_exception.dart';
import '../../core/policies.dart';
import '../../http/http_adapter.dart';

/// Decides whether and when to retry a failed request.
class RetryPolicy implements RetryPolicyInterface {
  RetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 30),
    this.retryOnStatus = const {408, 429, 500, 502, 503, 504},
    this.retryOnException = _defaultRetryOnException,
    this.useJitter = true,
    this.respectRetryAfter = true,
    this.safeMethods = const {'GET', 'HEAD', 'OPTIONS'},
  });

  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Set<int> retryOnStatus;
  final bool Function(ApiException error) retryOnException;
  final bool useJitter;
  final bool respectRetryAfter;
  final Set<String> safeMethods;

  /// Shared RNG. A fresh `Random()` per call is clock-seeded, so many clients
  /// retrying within the same millisecond under a thundering-herd 503 get
  /// correlated jitter and fire in lockstep — defeating the point of jitter.
  static final Random _random = Random();

  /// Exponential backoff convenience factory.
  factory RetryPolicy.exponential({
    int maxAttempts = 3,
    Duration baseDelay = const Duration(milliseconds: 200),
    Duration maxDelay = const Duration(seconds: 30),
    Set<int>? retryOnStatus,
    Set<String>? safeMethods,
  }) =>
      RetryPolicy(
        maxAttempts: maxAttempts,
        baseDelay: baseDelay,
        maxDelay: maxDelay,
        retryOnStatus: retryOnStatus ?? const {408, 429, 500, 502, 503, 504},
        safeMethods: safeMethods ?? const {'GET', 'HEAD', 'OPTIONS'},
      );

  bool shouldRetryResponse(
    AdapterResponse res,
    int attempt, {
    String method = 'GET',
  }) {
    if (attempt >= maxAttempts) return false;
    if (!safeMethods.contains(method.toUpperCase())) return false;
    return retryOnStatus.contains(res.statusCode);
  }

  bool shouldRetryError(ApiException err, int attempt,
      {String method = 'GET'}) {
    if (attempt >= maxAttempts) return false;
    if (!safeMethods.contains(method.toUpperCase())) return false;
    return retryOnException(err);
  }

  Duration delayFor(int attempt, AdapterResponse? res) {
    if (respectRetryAfter && res != null) {
      final retryAfter = _parseRetryAfter(res);
      if (retryAfter != null) {
        // Never let a server (or a buggy/hostile one) wedge a request past
        // our own ceiling: a `Retry-After: 86400` must not become a 24h wait.
        return retryAfter > maxDelay ? maxDelay : retryAfter;
      }
    }
    final pow = (1 << (attempt - 1).clamp(0, 16));
    final raw = baseDelay * pow;
    final capped = raw > maxDelay ? maxDelay : raw;
    if (!useJitter) return capped;
    // Full jitter: uniform in [0, capped]. Decorrelates concurrent retries
    // far better than the old additive `capped + small offset`, which also
    // could exceed maxDelay.
    final jittered = (_random.nextDouble() * capped.inMilliseconds).round();
    return Duration(milliseconds: jittered);
  }

  /// Parses a `Retry-After` header per RFC 7231: either delta-seconds or an
  /// HTTP-date. Returns null for a missing, negative, or unparseable value
  /// so the caller falls back to exponential backoff.
  Duration? _parseRetryAfter(AdapterResponse res) {
    final ra =
        (res.headers['retry-after'] ?? res.headers['Retry-After'])?.trim();
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
  static DateTime? _tryParseHttpDate(String value) {
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
}

bool _defaultRetryOnException(ApiException error) =>
    error is NetworkError || error is TimeoutError;
