import '../../core/api_exception.dart';
import '../../core/request_options.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import '../internal_headers.dart';

/// One completed request as observed by [MetricsInterceptor]: the final
/// outcome of a logical call, spanning every retry attempt.
class ApiRequestMetric {
  /// Creates a metric. Constructed by [MetricsInterceptor]; user code only
  /// reads these.
  const ApiRequestMetric({
    required this.method,
    required this.endpoint,
    required this.startedAt,
    required this.duration,
    required this.attempts,
    required this.fromCache,
    this.statusCode,
    this.error,
    this.tag,
  });

  /// HTTP method of the request (e.g. `GET`).
  final String method;

  /// Path or absolute URL as passed to the client, before query resolution.
  final String endpoint;

  /// When the first attempt entered the interceptor chain.
  final DateTime startedAt;

  /// Wall-clock time from the first attempt to the final outcome, including
  /// retry backoff waits.
  final Duration duration;

  /// Chain passes observed for this call (1 = no retries). Counts every
  /// restart of the chain, whichever interceptor triggered it.
  final int attempts;

  /// True when the response was served from the cache store rather than the
  /// network.
  final bool fromCache;

  /// Final HTTP status code, or null when the call failed without a response
  /// (network error, timeout, cancellation).
  final int? statusCode;

  /// Final error for a failed call; null on success. Note the client itself
  /// still surfaces this via [ApiResult] — it is echoed here so metrics
  /// pipelines see outcomes without wrapping every call site.
  final ApiException? error;

  /// The request's [RequestOptions.tag], for correlating with call sites.
  final Object? tag;

  /// True when the call completed with a response (any status), false when it
  /// failed with [error].
  bool get completed => error == null;

  @override
  String toString() =>
      'ApiRequestMetric($method $endpoint → '
      '${error == null ? 'HTTP $statusCode' : error.runtimeType} '
      'in ${duration.inMilliseconds}ms, attempts: $attempts'
      '${fromCache ? ', from cache' : ''})';
}

/// Reports one [ApiRequestMetric] per logical request — success or failure —
/// to [onMetric], for wiring into logging, analytics, or APM backends.
///
/// Place it FIRST in the interceptor list. The chain calls the first
/// interceptor's hooks at the outermost layer, so metrics sees the very first
/// attempt start and only the FINAL outcome (retries handled by inner
/// interceptors restart the chain without reaching it), giving one event per
/// call with total duration and attempt count:
///
/// ```dart
/// interceptors: [
///   MetricsInterceptor(onMetric: (m) => analytics.track('api', {
///     'endpoint': m.endpoint,
///     'ms': m.duration.inMilliseconds,
///     'status': m.statusCode,
///   })),
///   RetryInterceptor(policy: RetryPolicy()),
///   CacheInterceptor(store: MemoryCacheStore()),
/// ]
/// ```
///
/// Exceptions thrown by [onMetric] are swallowed — observability must never
/// affect request flow.
class MetricsInterceptor extends Interceptor {
  /// Creates an interceptor reporting to [onMetric].
  MetricsInterceptor({required this.onMetric});

  /// Called once per logical request with its final outcome.
  final void Function(ApiRequestMetric metric) onMetric;

  /// Per-call state, keyed by the request's [RequestOptions] instance: the
  /// client resolves a fresh options object per call and every retry copy
  /// shares it, so it identifies the logical request across chain restarts.
  /// An Expando (not a Map) so an abandoned call can never leak an entry.
  final Expando<_Tracker> _trackers = Expando<_Tracker>();

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    final tracker = _trackers[req.options] ??= _Tracker();
    tracker.attempts++;
    return ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    _finish(
      req,
      statusCode: res.statusCode,
      fromCache: headerValue(res.headers, cacheHitHeader) == cacheHitValue,
    );
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    _finish(req, error: error);
    return RejectResult(error);
  }

  void _finish(
    InterceptedRequest req, {
    int? statusCode,
    ApiException? error,
    bool fromCache = false,
  }) {
    // A response can short-circuit from an interceptor whose onRequest ran
    // before ours never did (not possible when placed first, but be robust to
    // any placement): fall back to a zero-duration single-attempt tracker.
    final tracker = _trackers[req.options] ?? _Tracker();
    _trackers[req.options] = null;
    final metric = ApiRequestMetric(
      method: req.method,
      endpoint: req.endpoint,
      startedAt: tracker.startedAt,
      duration: tracker.stopwatch.elapsed,
      attempts: tracker.attempts == 0 ? 1 : tracker.attempts,
      fromCache: fromCache,
      statusCode: statusCode,
      error: error,
      tag: req.options.tag,
    );
    try {
      onMetric(metric);
    } catch (_) {
      // Listener errors must not affect request flow.
    }
  }
}

class _Tracker {
  _Tracker()
      : startedAt = DateTime.now(),
        stopwatch = Stopwatch()..start();

  final DateTime startedAt;
  final Stopwatch stopwatch;
  int attempts = 0;
}
