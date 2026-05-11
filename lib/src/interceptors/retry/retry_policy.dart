import 'dart:math';

import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';

/// Decides whether and when to retry a failed request.
class RetryPolicy {
  RetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 30),
    this.retryOnStatus = const {408, 429, 500, 502, 503, 504},
    this.retryOnException = _defaultRetryOnException,
    this.useJitter = true,
    this.respectRetryAfter = true,
  });

  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Set<int> retryOnStatus;
  final bool Function(ApiException error) retryOnException;
  final bool useJitter;
  final bool respectRetryAfter;

  /// Exponential backoff convenience factory.
  factory RetryPolicy.exponential({
    int maxAttempts = 3,
    Duration baseDelay = const Duration(milliseconds: 200),
    Duration maxDelay = const Duration(seconds: 30),
    Set<int>? retryOnStatus,
  }) => RetryPolicy(
    maxAttempts: maxAttempts,
    baseDelay: baseDelay,
    maxDelay: maxDelay,
    retryOnStatus: retryOnStatus ?? const {408, 429, 500, 502, 503, 504},
  );

  bool shouldRetryResponse(AdapterResponse res, int attempt) {
    if (attempt >= maxAttempts) return false;
    return retryOnStatus.contains(res.statusCode);
  }

  bool shouldRetryError(ApiException err, int attempt) {
    if (attempt >= maxAttempts) return false;
    return retryOnException(err);
  }

  Duration delayFor(int attempt, AdapterResponse? res) {
    if (respectRetryAfter && res != null) {
      final ra = res.headers['retry-after'] ?? res.headers['Retry-After'];
      if (ra != null) {
        final secs = int.tryParse(ra.trim());
        if (secs != null) return Duration(seconds: secs);
      }
    }
    final pow = (1 << (attempt - 1).clamp(0, 16));
    final raw = baseDelay * pow;
    final capped = raw > maxDelay ? maxDelay : raw;
    if (!useJitter) return capped;
    final jitterMs = (Random().nextDouble() * capped.inMilliseconds * 0.3)
        .toInt();
    return Duration(milliseconds: capped.inMilliseconds + jitterMs);
  }
}

bool _defaultRetryOnException(ApiException error) =>
    error is NetworkError || error is TimeoutError;
