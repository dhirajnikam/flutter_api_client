import 'dart:async';

import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import '../internal_headers.dart';

/// Client-side request rate limiting via a token bucket.
///
/// Keeps this client under a request budget of [maxRequests] per [per],
/// independently for each bucket key (the request's host by default; override
/// with [keyOf]). Requests that arrive with the bucket empty wait for a token
/// in arrival order rather than failing, so bursts are smoothed instead of
/// dropped. The bucket starts full, so a burst of up to [maxRequests] passes
/// through instantly.
///
/// A request that would have to wait longer than [maxWait] is rejected
/// immediately with a [NetworkError] (the same fail-fast convention the
/// circuit breaker uses), so callers can bound their worst-case latency.
/// Cancelling a request's [CancelToken] while it is waiting releases it with
/// a [CancelError] and returns its token to the bucket.
///
/// When [respectRetryAfter] is true (the default) a 429 response additionally
/// pauses the whole bucket for the server's `Retry-After` duration (capped at
/// [maxServerPause]), so a server-side "slow down" is honored even by
/// requests that already hold a token.
///
/// Place it LAST in the interceptor list — after cache and dedup — so
/// responses served from the cache or piggybacked onto an in-flight duplicate
/// do not consume tokens:
///
/// ```dart
/// interceptors: [
///   RetryInterceptor(policy: RetryPolicy()),
///   CacheInterceptor(store: MemoryCacheStore()),
///   DedupInterceptor(),
///   RateLimitInterceptor(maxRequests: 10, per: const Duration(seconds: 1)),
/// ]
/// ```
///
/// Note: retries restart the chain, so each retry attempt is rate limited
/// like a fresh request — a retry storm cannot blow the budget.
class RateLimitInterceptor extends Interceptor {
  /// Creates a limiter allowing [maxRequests] per [per] for each bucket key.
  RateLimitInterceptor({
    required this.maxRequests,
    required this.per,
    this.maxWait,
    this.keyOf,
    this.respectRetryAfter = true,
    this.maxServerPause = const Duration(minutes: 5),
  })  : assert(maxRequests > 0, 'maxRequests must be positive'),
        assert(per > Duration.zero, 'per must be positive');

  /// Requests allowed per [per] (also the maximum burst size).
  final int maxRequests;

  /// The window [maxRequests] is spread over.
  final Duration per;

  /// Longest a request may wait for a token before being rejected with a
  /// [NetworkError]. `null` waits without bound.
  final Duration? maxWait;

  /// Maps a request to its bucket key. Defaults to the host of the resolved
  /// base URL, so each origin gets its own budget.
  final String Function(InterceptedRequest req)? keyOf;

  /// Whether a 429 response's `Retry-After` header pauses the bucket.
  final bool respectRetryAfter;

  /// Upper bound on a server-requested pause, so a buggy or hostile
  /// `Retry-After: 86400` cannot wedge the bucket for a day.
  final Duration maxServerPause;

  final Map<String, _Bucket> _buckets = {};

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    final preCancelled = req.options.cancelToken?.error;
    if (preCancelled != null) return RejectResult(preCancelled);

    final bucket = _buckets.putIfAbsent(
      _key(req),
      () => _Bucket(capacity: maxRequests.toDouble()),
    );

    final now = DateTime.now();
    bucket.refill(now, ratePerMicrosecond: _ratePerMicrosecond);

    // Reservation scheduling: consume a token unconditionally (tokens may go
    // negative) and compute how long this request must wait for its token to
    // exist. Arrivals are thereby served in FIFO order with no wake-up races.
    final deficit = 1 - bucket.tokens;
    bucket.tokens -= 1;
    var wait = deficit <= 0
        ? Duration.zero
        : Duration(microseconds: (deficit / _ratePerMicrosecond).ceil());

    // A server-requested pause delays the schedule for the whole bucket.
    final pausedUntil = bucket.pausedUntil;
    if (pausedUntil != null) {
      final pause = pausedUntil.difference(now);
      if (pause > wait) wait = pause;
    }

    if (wait <= Duration.zero) return ProceedResult(req);

    if (maxWait != null && wait > maxWait!) {
      bucket.tokens += 1; // Rejected: give the reserved token back.
      return RejectResult(
        NetworkError(
          'Rate limit for ${_key(req)}: next slot in '
          '${wait.inMilliseconds}ms exceeds maxWait '
          '${maxWait!.inMilliseconds}ms ($maxRequests requests per '
          '${per.inMilliseconds}ms).',
        ),
      );
    }

    final cancelToken = req.options.cancelToken;
    if (cancelToken == null) {
      await Future<void>.delayed(wait);
      return ProceedResult(req);
    }

    final cancelled = Completer<CancelError>();
    final removeListener = cancelToken.addListener((err) {
      if (!cancelled.isCompleted) cancelled.complete(err);
    });
    try {
      final winner = await Future.any<Object?>([
        Future<void>.delayed(wait),
        cancelled.future,
      ]);
      if (winner is CancelError) {
        bucket.tokens += 1; // Cancelled: give the reserved token back.
        if (bucket.tokens > bucket.capacity) bucket.tokens = bucket.capacity;
        return RejectResult(winner);
      }
      return ProceedResult(req);
    } finally {
      removeListener();
    }
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    if (respectRetryAfter && res.statusCode == 429) {
      final retryAfter = parseRetryAfter(res.headers);
      if (retryAfter != null && retryAfter > Duration.zero) {
        final pause = retryAfter > maxServerPause ? maxServerPause : retryAfter;
        final until = DateTime.now().add(pause);
        final bucket = _buckets.putIfAbsent(
          _key(req),
          () => _Bucket(capacity: maxRequests.toDouble()),
        );
        final existing = bucket.pausedUntil;
        if (existing == null || until.isAfter(existing)) {
          bucket.pausedUntil = until;
        }
      }
    }
    return ResolveResult(res);
  }

  double get _ratePerMicrosecond => maxRequests / per.inMicroseconds;

  /// Host of the resolved base URL; falls back to the endpoint's host for
  /// absolute-URL requests, then to a single shared bucket. Mirrors the
  /// circuit breaker's keying so both features agree on what "an origin" is.
  String _key(InterceptedRequest req) {
    final custom = keyOf;
    if (custom != null) return custom(req);
    final base = req.options.baseUrlOverride;
    if (base != null) {
      final host = Uri.tryParse(base)?.host;
      if (host != null && host.isNotEmpty) return host;
    }
    final host = Uri.tryParse(req.endpoint)?.host;
    if (host != null && host.isNotEmpty) return host;
    return '<default>';
  }
}

class _Bucket {
  _Bucket({required this.capacity})
      : tokens = capacity,
        lastRefill = DateTime.now();

  final double capacity;
  double tokens;
  DateTime lastRefill;
  DateTime? pausedUntil;

  /// Adds tokens for the time elapsed since the last refill, capped at
  /// [capacity]. Negative balances (queued reservations) refill through zero.
  void refill(DateTime now, {required double ratePerMicrosecond}) {
    final elapsed = now.difference(lastRefill).inMicroseconds;
    if (elapsed <= 0) return;
    lastRefill = now;
    tokens += elapsed * ratePerMicrosecond;
    if (tokens > capacity) tokens = capacity;
    final paused = pausedUntil;
    if (paused != null && !now.isBefore(paused)) pausedUntil = null;
  }
}
