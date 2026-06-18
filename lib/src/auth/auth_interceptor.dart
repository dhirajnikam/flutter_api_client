import 'dart:async';

import '../core/api_exception.dart';
import '../http/http_adapter.dart';
import '../interceptors/interceptor.dart';
import 'token_storage.dart';

/// Async function that refreshes the access token. Should return true on
/// success (storage is expected to be updated with the new token).
typedef RefreshTokenFn = Future<bool> Function();

/// Attaches the auth token, retries on 401 with concurrent-safe refresh.
///
/// When several requests fire in parallel and all receive 401, exactly one
/// refresh is invoked while the others wait on the same future.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.storage,
    this.refresh,
    this.authScheme = 'Bearer',
    this.retryStatusCodes = const {401},
  });

  final TokenStorage storage;
  final RefreshTokenFn? refresh;
  final String authScheme;
  final Set<int> retryStatusCodes;

  Future<bool>? _inFlight;

  static const _retriedHeader = 'x-fac-retried-auth';
  static const _tokenFpHeader = 'x-fac-auth-token-fp';

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    if (!req.options.includeToken) return ProceedResult(req);
    final token = await storage.getAccessToken();
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] =
          authScheme.isEmpty ? token : '$authScheme $token';
      // Record which token this attempt used (a non-reversible fingerprint,
      // never the token itself; this header is internal and stripped before
      // the wire). Used in [onResponse] to avoid a redundant refresh when a
      // concurrent flow has already rotated the token out from under us.
      req.headers[_tokenFpHeader] = _fingerprint(token);
    }
    return ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    if (!retryStatusCodes.contains(res.statusCode)) return ResolveResult(res);
    if (refresh == null) return ResolveResult(res);
    if (!req.options.includeToken) return ResolveResult(res);
    if ((req.headers[_retriedHeader] ?? '') == '1') {
      return ResolveResult(res);
    }

    // Concurrent-401 staleness guard: if the stored token already differs from
    // the one this request used, another request's refresh has landed. Retry
    // immediately with the current token instead of triggering a *second*
    // refresh that would needlessly rotate the just-minted valid token.
    final usedFp = req.headers[_tokenFpHeader];
    if (usedFp != null) {
      final current = await storage.getAccessToken();
      if (current != null &&
          current.isNotEmpty &&
          _fingerprint(current) != usedFp) {
        return ProceedResult(_retryRequest(req));
      }
    }

    final ok = await _refreshOnce();
    if (!ok) return ResolveResult(res);
    return ProceedResult(_retryRequest(req));
  }

  InterceptedRequest _retryRequest(InterceptedRequest req) {
    final retry = req.copy();
    retry.headers[_retriedHeader] = '1';
    // Drop the stale Authorization/fingerprint so onRequest re-attaches the
    // freshest token on the retry pass.
    retry.headers.remove('Authorization');
    retry.headers.remove(_tokenFpHeader);
    return retry;
  }

  /// Stable, non-reversible fingerprint of a token. Length + hashCode is
  /// enough to detect "the token changed" without ever copying the secret.
  String _fingerprint(String token) => '${token.length}:${token.hashCode}';

  Future<bool> _refreshOnce() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final f = Future(() async {
      try {
        return await refresh!();
      } on ApiException {
        return false;
      } catch (_) {
        return false;
      }
    });
    _inFlight = f;
    f.whenComplete(() => _inFlight = null);
    return f;
  }
}
