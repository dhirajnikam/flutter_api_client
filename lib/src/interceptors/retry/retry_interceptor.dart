import '../../core/api_exception.dart';
import '../../core/error_classification.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import '../internal_headers.dart';
import 'retry_policy.dart';

/// Retries failed requests according to a [RetryPolicy].
class RetryInterceptor extends Interceptor {
  RetryInterceptor({required this.policy});

  /// Applied unless a request overrides it via `RequestOptions.retryPolicy`.
  final RetryPolicy policy;
  static final _stateKey = Object();

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    final policy = _policyFor(req);
    final attempt = _state(req).attempt;
    // A cache-fabricated response (the 504 of a cacheOnly miss) is known
    // locally; backing off and retrying can never change it.
    if (isCacheFabricated(res)) return ResolveResult(res);
    if (policy.shouldRetryResponse(res, attempt, method: req.method)) {
      await Future.delayed(policy.delayFor(attempt, res));
      return ProceedResult(_nextAttempt(req, attempt, mayHaveSent: true));
    }
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    final policy = _policyFor(req);
    final (:attempt, :mayHaveSent) = _state(req);
    if (policy.shouldRetryError(error, attempt, method: req.method)) {
      await Future.delayed(policy.delayFor(attempt, null));
      return ProceedResult(_nextAttempt(
        req,
        attempt,
        mayHaveSent: mayHaveSent || !error.neverSent,
      ));
    }
    // NetworkError.sent describes only the last attempt. If an earlier one may
    // have reached the server (e.g. a breaker opened between attempts), the
    // call as a whole is ambiguous, so do not let the final error claim
    // otherwise.
    if (error.neverSent && mayHaveSent) {
      return RejectResult(NetworkError(
        error.message,
        // One hop to the transport cause; a breaker rejection has none, so it
        // becomes the cause itself (the breaker follows it to spot its own).
        cause: error.cause ?? error,
        stackTrace: error.stackTrace,
      ));
    }
    return RejectResult(error);
  }

  RetryPolicy _policyFor(InterceptedRequest req) {
    final override = req.options.retryPolicy;
    return override is RetryPolicy ? override : policy;
  }

  /// The attempt number, and whether an earlier attempt may have reached the
  /// server.
  ({int attempt, bool mayHaveSent}) _state(InterceptedRequest req) =>
      req.extra[_stateKey] as ({int attempt, bool mayHaveSent})? ??
      (attempt: 1, mayHaveSent: false);

  InterceptedRequest _nextAttempt(
    InterceptedRequest req,
    int attempt, {
    required bool mayHaveSent,
  }) {
    final next = req.copy();
    next.extra[_stateKey] = (attempt: attempt + 1, mayHaveSent: mayHaveSent);
    return next;
  }
}
