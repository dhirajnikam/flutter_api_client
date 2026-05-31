import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import 'retry_policy.dart';

/// Retries failed requests according to a [RetryPolicy].
class RetryInterceptor extends Interceptor {
  RetryInterceptor({required this.policy});

  final RetryPolicy policy;
  static const _attemptHeader = 'x-fac-retry-attempt';

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    final policy = _policyFor(req);
    final attempt = _attempt(req);
    if (policy.shouldRetryResponse(res, attempt, method: req.method)) {
      await Future.delayed(policy.delayFor(attempt, res));
      final next = req.copy();
      next.headers[_attemptHeader] = '${attempt + 1}';
      return ProceedResult(next);
    }
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    final policy = _policyFor(req);
    final attempt = _attempt(req);
    if (policy.shouldRetryError(error, attempt, method: req.method)) {
      await Future.delayed(policy.delayFor(attempt, null));
      final next = req.copy();
      next.headers[_attemptHeader] = '${attempt + 1}';
      return ProceedResult(next);
    }
    return RejectResult(error);
  }

  RetryPolicy _policyFor(InterceptedRequest req) {
    final override = req.options.retryPolicy;
    return override is RetryPolicy ? override : policy;
  }

  int _attempt(InterceptedRequest req) =>
      int.tryParse(req.headers[_attemptHeader] ?? '1') ?? 1;
}
