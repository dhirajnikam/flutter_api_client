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

  /// HTTP methods eligible for coalescing (compared case-insensitively).
  final Set<String> methods;

  /// Maximum time a follower waits for the in-flight leader before giving up
  /// and issuing its own request. Guards against a leader that never reaches
  /// `onResponse`/`onError`, which would otherwise hang followers forever.
  final Duration waitTimeout;

  final Map<String, Completer<AdapterResponse>> _inFlight = {};
  static final _ownedKey = Object();

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    if (!methods.contains(req.method.toUpperCase())) return ProceedResult(req);
    // Re-entry guard: a retry re-runs the chain with a copy that already owns
    // an in-flight entry. Without this, the leader would await its own
    // completer and deadlock. Ownership, not the current key, decides: an
    // interceptor further down may have changed a header since, and the entry
    // is released under the key it was registered with.
    if (req.extra[_ownedKey] != null) return ProceedResult(req);
    final key = requestIdentityKey(req);
    final existing = _inFlight[key];
    if (existing != null) {
      final ownToken = req.options.cancelToken;
      try {
        var wait = existing.future.timeout(waitTimeout);
        if (ownToken != null) {
          // Race the wait against the follower's OWN token so its cancel is
          // honoured promptly instead of blocking until the leader settles or
          // the waitTimeout elapses. Future.any observes the losing future,
          // so the leader's error stays handled either way.
          wait = Future.any([
            wait,
            ownToken.whenCancelled.then<AdapterResponse>((err) => throw err),
          ]);
        }
        final res = await wait;
        return ResolveResult(res);
      } on TimeoutException {
        // Leader appears stuck; proceed independently without disturbing it.
        return ProceedResult(req);
      } on _DedupNotShareable {
        // Leader returned a single-subscription stream that can't be shared.
        // Proceed independently rather than failing the follower.
        return ProceedResult(req);
      } on CancelError catch (e) {
        // The follower's own token fired: fail with its own error.
        if (ownToken?.isCancelled ?? false) {
          return RejectResult(ownToken!.error ?? e);
        }
        // The LEADER was cancelled — the follower is innocent (its token was
        // never cancelled), so issue its own request instead of inheriting a
        // CancelError that no retry policy would retry.
        return ProceedResult(req);
      }
      // Any other error (the leader's ApiException) intentionally propagates:
      // a coalesced follower shares the leader's failure.
    }
    final completer = Completer<AdapterResponse>();
    // Always attach a no-op observer to the leader's future. The completer is
    // otherwise observed only by coalesced followers; a leader that errors or
    // returns an unshareable stream while it has ZERO followers would complete
    // with an error that has no listener, which Dart surfaces as an *unhandled
    // asynchronous error* in the surrounding zone (crashing a
    // `runZonedGuarded` app). This observer guarantees the error is always
    // consumed; a real follower still receives it independently via its own
    // `await existing.future`.
    unawaited(completer.future.then((_) {}, onError: (_) {}));
    _inFlight[key] = completer;
    req.extra[_ownedKey] = key;
    return ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    final c = _release(req);
    if (c != null && !c.isCompleted) {
      if (res.bodyStream == null) {
        c.complete(res);
      } else {
        // A streaming body is single-subscription and cannot be shared with
        // followers. Complete with an error so any follower already awaiting
        // the leader is released *immediately* and falls back to its own
        // request, instead of blocking for the full [waitTimeout].
        c.completeError(const _DedupNotShareable());
      }
    }
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    final c = _release(req);
    if (c != null && !c.isCompleted) c.completeError(error);
    return RejectResult(error);
  }

  /// Ends [req]'s ownership together with its in-flight entry, so a restart
  /// from an interceptor above this one re-enters as a fresh request instead
  /// of bypassing dedup and later releasing somebody else's entry.
  Completer<AdapterResponse>? _release(InterceptedRequest req) {
    final c = _inFlight.remove(req.extra[_ownedKey]);
    req.extra[_ownedKey] = null;
    return c;
  }
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
