import '../../core/api_exception.dart';
import '../../core/error_classification.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import '../internal_headers.dart';

/// State of one circuit inside [CircuitBreakerInterceptor].
enum CircuitState {
  /// Requests flow normally; consecutive failures are counted.
  closed,

  /// The origin is considered down; requests fail fast without transport.
  open,

  /// Cooldown elapsed; a single probe request is allowed through to test
  /// whether the origin recovered. If its outcome is not recorded within the
  /// cooldown (e.g. cancelled), a fresh probe replaces it.
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
/// it for another cooldown. Only probes move an open or half-open circuit: a
/// request admitted before it opened that finishes late is ignored, as is any
/// response the cache marked as its own (including a 304 it revalidated, so
/// such a probe leaves the circuit half-open until the next probe). A probe
/// whose outcome goes unrecorded for a whole cooldown (e.g. slow, or
/// cancelled) is replaced by a fresh one; if a replaced probe (one of the last
/// 16) later succeeds it still closes the circuit, so a slow but healthy
/// origin can recover, but its failure is ignored.
///
/// Place it BEFORE `RetryInterceptor` in the interceptor list so retries of a
/// tripped host are also cut short. In that order the breaker sees only each
/// call's final outcome, so [failureThreshold] counts failed calls, not
/// individual retry attempts. In that order the half-open probe's own retries
/// are let through, and its final outcome closes or reopens the circuit.
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
  CircuitBreakerInterceptor({
    this.failureThreshold = 5,
    this.cooldown = const Duration(seconds: 30),
    this.onStateChange,
    DateTime Function()? now,
  })  : _now = now ?? _monotonicNow(),
        assert(failureThreshold > 0, 'failureThreshold must be positive'),
        assert(cooldown > Duration.zero, 'cooldown must be positive');

  /// Clock for cooldowns; injectable so tests need not sleep.
  final DateTime Function() _now;

  /// Wall-clock start plus a [Stopwatch], so a system clock change cannot
  /// stretch or skip a cooldown.
  static DateTime Function() _monotonicNow() {
    final start = DateTime.now();
    final watch = Stopwatch()..start();
    return () => start.add(watch.elapsed);
  }

  /// Consecutive failures that trip a closed circuit open.
  final int failureThreshold;

  /// How long an open circuit rejects before allowing a probe.
  final Duration cooldown;

  /// Called whenever a circuit changes state, with the host key and the new
  /// state. Exceptions it throws are swallowed.
  final void Function(String host, CircuitState state)? onStateChange;

  final Map<String, _Circuit> _circuits = {};

  static final _probeKey = Object();

  /// Rejections this breaker fabricated itself, so the chain's own onError pass
  /// over this interceptor does not count a fail-fast rejection as another
  /// origin failure. Weak: a rejection retried by an interceptor below this one
  /// never comes back here, and must not be held forever.
  final Expando<bool> _synthetic = Expando();

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
        // The probe's own retries (restarted by an interceptor below this one)
        // must reach the origin, or its failure is never recorded.
        if (_isProbe(req, circuit)) return ProceedResult(req);
        // One probe is already in flight; hold the rest back. Its outcome can
        // go unrecorded (e.g. cancelled), so after another cooldown let a new
        // probe through instead of staying half-open forever.
        if (_now().isBefore(circuit.reopenAt!)) return _rejectFast(req);
        return _admitProbe(req, circuit);
      case CircuitState.open:
        if (_now().isBefore(circuit.reopenAt!)) return _rejectFast(req);
        _transition(_key(req), circuit, CircuitState.halfOpen);
        return _admitProbe(req, circuit);
    }
  }

  /// Whether [req] is the current probe (its retries may pass the hold-back).
  bool _isProbe(InterceptedRequest req, _Circuit circuit) =>
      circuit.probe != null && req.extra[_probeKey] == circuit.probe;

  /// Whether [req] is any probe admitted since the circuit last closed. A probe
  /// replaced after its lease ran out still reports a real origin outcome, so
  /// a slow but healthy origin can close the circuit.
  bool _isAnyProbe(InterceptedRequest req, _Circuit circuit) {
    final token = req.extra[_probeKey];
    return token != null && circuit.probes.contains(token);
  }

  /// Starts the probe's lease and tags [req] so its retries are recognised.
  InterceptorResult _admitProbe(InterceptedRequest req, _Circuit circuit) {
    circuit
      ..reopenAt = _now().add(cooldown)
      ..probe = Object();
    circuit.probes.add(circuit.probe!);
    // Bounded: a probe older than this many leases is treated as stale.
    if (circuit.probes.length > 16) circuit.probes.removeAt(0);
    req.extra[_probeKey] = circuit.probe;
    return ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    // A response the cache served locally (a hit, or the synthetic 504 of a
    // cacheOnly miss) says nothing about the origin.
    if (isCacheFabricated(res)) return ResolveResult(res);
    // 5xx counts as a failure (the origin is unhealthy); anything else —
    // including 4xx — proves the origin is up and resets the circuit.
    _record(req, failure: res.statusCode >= 500);
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    if (_isSynthetic(error)) return RejectResult(error);
    if (error.isTransient) _record(req, failure: true);
    // CancelError and every other error type says nothing about origin
    // health; leave the circuit untouched.
    return RejectResult(error);
  }

  InterceptorResult _rejectFast(InterceptedRequest req) {
    final err = NetworkError(
      'Circuit breaker open for ${_key(req)}: failing fast '
      '(origin marked down after $failureThreshold consecutive failures).',
      sent: false,
    );
    _synthetic[err] = true;
    return RejectResult(err);
  }

  /// Follows `cause`, since `RetryInterceptor` re-wraps a fail-fast rejection
  /// (as `sent: true`) when an earlier attempt may have reached the server.
  bool _isSynthetic(Object? error) {
    for (var e = error; e is ApiException; e = e.cause) {
      if (_synthetic[e] ?? false) return true;
    }
    return false;
  }

  void _record(InterceptedRequest req, {required bool failure}) {
    final key = _key(req);
    final circuit = _circuits.putIfAbsent(key, () => _Circuit());
    if (circuit.state != CircuitState.closed) {
      // While open or half-open only probes count: a request admitted before
      // the circuit opened that finishes late says nothing about it now.
      if (!_isAnyProbe(req, circuit)) return;
      if (!failure) {
        circuit
          ..consecutiveFailures = 0
          ..reopenAt = null
          ..probe = null
          ..probes.clear();
        _transition(key, circuit, CircuitState.closed);
      } else if (circuit.state == CircuitState.halfOpen &&
          _isProbe(req, circuit)) {
        // Only the current probe's failure reopens it; a replaced probe that
        // fails late must not cut short the one still in flight.
        circuit
          ..reopenAt = _now().add(cooldown)
          ..probe = null;
        _transition(key, circuit, CircuitState.open);
      }
      return;
    }
    if (!failure) {
      circuit.consecutiveFailures = 0;
      return;
    }
    if (++circuit.consecutiveFailures >= failureThreshold) {
      circuit.reopenAt = _now().add(cooldown);
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
  Object? probe; // token of the current half-open probe
  final List<Object> probes = []; // tokens admitted since the last close
}
