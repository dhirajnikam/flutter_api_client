import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';

/// State of one circuit inside [CircuitBreakerInterceptor].
enum CircuitState {
  /// Requests flow normally; consecutive failures are counted.
  closed,

  /// The origin is considered down; requests fail fast without transport.
  open,

  /// Cooldown elapsed; a single probe request is allowed through to test
  /// whether the origin recovered.
  halfOpen,
}

/// Fails fast when an origin looks down, instead of letting every request
/// wait out its full timeout.
///
/// Circuits are keyed per host (from the request's resolved base URL). Each
/// circuit is `closed` until [failureThreshold] consecutive transport
/// failures (network/timeout errors, plus HTTP 5xx responses) occur; it then
/// `open`s and every request to that host is rejected immediately with a
/// [NetworkError] for [cooldown]. After the cooldown one probe request is
/// allowed through (`halfOpen`): success closes the circuit, failure reopens
/// it for another cooldown.
///
/// Place it BEFORE `RetryInterceptor` in the interceptor list so retries of a
/// tripped host are also cut short.
///
/// ```dart
/// interceptors: [
///   CircuitBreakerInterceptor(failureThreshold: 5,
///       cooldown: const Duration(seconds: 30)),
///   RetryInterceptor(policy: RetryPolicy()),
/// ]
/// ```
///
/// Cancellation ([CancelError]) and 4xx responses are not failures — they
/// prove the origin is reachable (or say nothing about it).
class CircuitBreakerInterceptor extends Interceptor {
  /// Creates a breaker with the given thresholds.
  CircuitBreakerInterceptor({
    this.failureThreshold = 5,
    this.cooldown = const Duration(seconds: 30),
    this.onStateChange,
  })  : assert(failureThreshold > 0, 'failureThreshold must be positive'),
        assert(cooldown > Duration.zero, 'cooldown must be positive');

  /// Consecutive failures that trip a closed circuit open.
  final int failureThreshold;

  /// How long an open circuit rejects before allowing a probe.
  final Duration cooldown;

  /// Called whenever a circuit changes state, with the host key and the new
  /// state. Exceptions it throws are swallowed.
  final void Function(String host, CircuitState state)? onStateChange;

  final Map<String, _Circuit> _circuits = {};

  /// Rejections this breaker fabricated itself. Tracked by identity so the
  /// chain's own onError pass over this interceptor does not count a
  /// fail-fast rejection as another origin failure.
  final Set<ApiException> _synthetic = {};

  /// Current state of the circuit for [host] (as produced by the request's
  /// resolved base URL). Reads do not advance the open→halfOpen transition.
  CircuitState stateFor(String host) =>
      _circuits[host]?.state ?? CircuitState.closed;

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    final circuit = _circuits.putIfAbsent(_key(req), () => _Circuit());
    switch (circuit.state) {
      case CircuitState.closed:
        return ProceedResult(req);
      case CircuitState.halfOpen:
        // One probe is already in flight; hold the rest back.
        return _rejectFast(req);
      case CircuitState.open:
        if (DateTime.now().isBefore(circuit.reopenAt!)) {
          return _rejectFast(req);
        }
        _transition(_key(req), circuit, CircuitState.halfOpen);
        return ProceedResult(req); // the probe
    }
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    // 5xx counts as a failure (the origin is unhealthy); anything else —
    // including 4xx — proves the origin is up and resets the circuit.
    _record(_key(req), failure: res.statusCode >= 500);
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    if (_synthetic.remove(error)) return RejectResult(error);
    if (error is NetworkError || error is TimeoutError) {
      _record(_key(req), failure: true);
    }
    // CancelError and every other error type says nothing about origin
    // health; leave the circuit untouched.
    return RejectResult(error);
  }

  InterceptorResult _rejectFast(InterceptedRequest req) {
    final err = NetworkError(
      'Circuit breaker open for ${_key(req)}: failing fast '
      '(origin marked down after $failureThreshold consecutive failures).',
    );
    _synthetic.add(err);
    return RejectResult(err);
  }

  void _record(String key, {required bool failure}) {
    final circuit = _circuits.putIfAbsent(key, () => _Circuit());
    if (!failure) {
      circuit
        ..consecutiveFailures = 0
        ..reopenAt = null;
      _transition(key, circuit, CircuitState.closed);
      return;
    }
    if (circuit.state == CircuitState.halfOpen) {
      // Probe failed: straight back to open for another cooldown.
      circuit.reopenAt = DateTime.now().add(cooldown);
      _transition(key, circuit, CircuitState.open);
      return;
    }
    circuit.consecutiveFailures++;
    if (circuit.state == CircuitState.closed &&
        circuit.consecutiveFailures >= failureThreshold) {
      circuit.reopenAt = DateTime.now().add(cooldown);
      _transition(key, circuit, CircuitState.open);
    }
  }

  void _transition(String key, _Circuit circuit, CircuitState next) {
    if (circuit.state == next) return;
    circuit.state = next;
    final cb = onStateChange;
    if (cb == null) return;
    try {
      cb(key, next);
    } catch (_) {
      // Listener errors must not affect request flow.
    }
  }

  /// Host of the resolved base URL; falls back to the endpoint's host for
  /// absolute-URL requests, then to a single shared bucket.
  String _key(InterceptedRequest req) {
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

class _Circuit {
  CircuitState state = CircuitState.closed;
  int consecutiveFailures = 0;
  DateTime? reopenAt;
}
