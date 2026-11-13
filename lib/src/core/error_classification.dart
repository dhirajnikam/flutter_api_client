import 'api_exception.dart';

/// How the resilience features (retry, cache fallback, circuit breaker,
/// offline queue) read an [ApiException].
extension ApiExceptionClassification on ApiException {
  /// The origin may simply have been unreachable: trying again later can
  /// succeed without the request itself changing.
  bool get isTransient => this is NetworkError || this is TimeoutError;

  /// The request provably never left the device, so re-sending it cannot
  /// duplicate it.
  bool get neverSent {
    final self = this;
    return self is NetworkError && !self.sent;
  }
}
