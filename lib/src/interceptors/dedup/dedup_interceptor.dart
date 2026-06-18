import 'dart:async';

import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import '../request_identity.dart';

/// Coalesces identical in-flight GET requests so the network is only hit
/// once. Other matching callers receive the same response.
class DedupInterceptor extends Interceptor {
  DedupInterceptor({
    this.methods = const {'GET', 'HEAD'},
    this.waitTimeout = const Duration(seconds: 30),
  });

  final Set<String> methods;

  /// Maximum time a follower waits for the in-flight leader before giving up
  /// and issuing its own request. Guards against a leader that never reaches
  /// `onResponse`/`onError`, which would otherwise hang followers forever.
  final Duration waitTimeout;

  final Map<String, Completer<AdapterResponse>> _inFlight = {};
  static const _keyHeader = 'x-fac-dedup-key';

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    if (!methods.contains(req.method.toUpperCase())) return ProceedResult(req);
    final key = _key(req);
    // Re-entry guard: a retry re-runs the chain with a copy that still carries
    // our key header. Without this, the leader would await its own completer
    // and deadlock. The owner of the key always proceeds.
    if (req.headers[_keyHeader] == key) return ProceedResult(req);
    final existing = _inFlight[key];
    if (existing != null) {
      try {
        final res = await existing.future.timeout(waitTimeout);
        return ResolveResult(res);
      } on TimeoutException {
        // Leader appears stuck; proceed independently without disturbing it.
        return ProceedResult(req);
      } on _DedupNotShareable {
        // Leader returned a single-subscription stream that can't be shared.
        // Proceed independently rather than failing the follower.
        return ProceedResult(req);
      }
      // Any other error (the leader's ApiException) intentionally propagates:
      // a coalesced follower shares the leader's failure.
    }
    _inFlight[key] = Completer<AdapterResponse>();
    req.headers[_keyHeader] = key;
    return ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    final key = req.headers[_keyHeader];
    if (key != null) {
      final c = _inFlight.remove(key);
      if (c != null && !c.isCompleted) {
        if (res.bodyStream == null) {
          c.complete(res);
        } else {
          // A streaming body is single-subscription and cannot be shared with
          // followers. Complete with an error so any follower already awaiting
          // the leader is released *immediately* and falls back to its own
          // request, instead of blocking for the full [waitTimeout].
          c.completeError(
            const _DedupNotShareable(),
          );
        }
      }
    }
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    final key = req.headers[_keyHeader];
    if (key != null) {
      final c = _inFlight.remove(key);
      if (c != null && !c.isCompleted) c.completeError(error);
    }
    return RejectResult(error);
  }

  String _key(InterceptedRequest req) => requestIdentityKey(req);
}

/// Internal signal: the leader produced a streaming (single-subscription)
/// response that cannot be shared with coalesced followers. Caught inside the
/// interceptor to release waiting followers immediately; never surfaces to
/// callers.
class _DedupNotShareable implements Exception {
  const _DedupNotShareable();
  @override
  String toString() =>
      'Dedup leader response is not shareable (streaming body)';
}
