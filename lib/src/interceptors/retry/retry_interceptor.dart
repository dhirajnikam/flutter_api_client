import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import '../internal_headers.dart';
import 'retry_policy.dart';

/// Retries failed requests according to a [RetryPolicy].
class RetryInterceptor extends Interceptor {
  /// Creates an interceptor that retries using [policy], unless a request
  /// overrides it via [RequestOptions.retryPolicy].
  RetryInterceptor({required this.policy});

  /// The default retry policy applied when a request supplies no override.
  final RetryPolicy policy;
  static const _attemptHeader = 'x-fac-retry-attempt';

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    final policy = _policyFor(req);
    final attempt = _attempt(req);
    if (_isSyntheticCacheMiss(res)) return ResolveResult(res);
    if (policy.shouldRetryResponse(res, attempt, method: req.method)) {
      await Future.delayed(policy.delayFor(attempt, res));
      return ProceedResult(_nextAttempt(req, attempt));
    }
    return ResolveResult(res);
  }

  /// Whether [res] is the synthetic 504 the cache interceptor fabricates for
  /// a cacheOnly miss. The miss is known synchronously and locally, so backing
  /// off and retrying it can never change the outcome. The marker is trusted
  /// only on a 504 whose value matches the synthetic constant exactly; a real
  /// origin could in principle echo the same header on a genuine 504 and
  /// suppress its retries, which we accept — it only skips retries of an
  /// already-failing response.
  bool _isSyntheticCacheMiss(AdapterResponse res) =>
      res.statusCode == 504 &&
      headerValue(res.headers, cacheHitHeader) == cacheMissValue;

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    final policy = _policyFor(req);
    final attempt = _attempt(req);
    if (policy.shouldRetryError(error, attempt, method: req.method)) {
      await Future.delayed(policy.delayFor(attempt, null));
      return ProceedResult(_nextAttempt(req, attempt));
    }
    return RejectResult(error);
  }

  RetryPolicy _policyFor(InterceptedRequest req) {
    final override = req.options.retryPolicy;
    return override is RetryPolicy ? override : policy;
  }

  int _attempt(InterceptedRequest req) =>
      int.tryParse(req.headers[_attemptHeader] ?? '1') ?? 1;

  InterceptedRequest _nextAttempt(InterceptedRequest req, int attempt) {
    final next = req.copy();
    next.headers[_attemptHeader] = '${attempt + 1}';
    return next;
  }
}
