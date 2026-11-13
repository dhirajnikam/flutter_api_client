import 'dart:async';

import '../http/http_adapter.dart';
import '../interceptors/interceptor.dart';
import '../interceptors/internal_headers.dart';
import 'token_storage.dart';

/// Async function that refreshes the access token. Returns true on success.
///
/// On success it MUST have written the new access token to the same
/// [TokenStorage] the interceptor reads from, and MUST NOT complete until that
/// write is observable — the retry re-reads the token via
/// [TokenStorage.getAccessToken] immediately after this future resolves. Wrap a
/// slow backend in [CachedTokenStorage] so the new token is readable from the
/// in-memory cache the instant it is set, even while the disk write is still
/// in flight.
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
    this.headerName = 'Authorization',
  });

  final TokenStorage storage;
  final RefreshTokenFn? refresh;
  final String authScheme;
  final Set<int> retryStatusCodes;

  /// HTTP header the token is written to. Defaults to `Authorization`.
  ///
  /// Whatever the name, the bundled loggers redact it and the offline queue
  /// never persists it.
  final String headerName;

  Future<bool>? _inFlight;

  static final _retriedKey = Object();
  static final _usedTokenKey = Object();

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    // Recorded even when no token is attached: a caller may supply the header
    // itself, and it must still be kept out of logs and the offline queue.
    req.extra[credentialHeaderKey] = headerName;
    if (!req.options.includeToken) return ProceedResult(req);
    final token = await storage.getAccessToken();
    if (token != null && token.isNotEmpty) {
      req.headers[headerName] =
          authScheme.isEmpty ? token : '$authScheme $token';
      req.extra[_usedTokenKey] = token;
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
    if (req.extra[_retriedKey] == true) return ResolveResult(res);

    // Concurrent-401 staleness guard: if the stored token already differs from
    // the one this request used, another request's refresh has landed. Retry
    // immediately with the current token instead of triggering a *second*
    // refresh that would needlessly rotate the just-minted valid token.
    final used = req.extra[_usedTokenKey];
    if (used != null) {
      final current = await storage.getAccessToken();
      if (current != null && current.isNotEmpty && current != used) {
        return ProceedResult(_retryRequest(req));
      }
    }

    final ok = await _refreshOnce();
    if (!ok) return ResolveResult(res);
    return ProceedResult(_retryRequest(req));
  }

  InterceptedRequest _retryRequest(InterceptedRequest req) {
    final retry = req.copy();
    retry.extra[_retriedKey] = true;
    // Drop the stale token so onRequest re-attaches the freshest one on the
    // retry pass.
    retry.headers.remove(headerName);
    return retry;
  }

  Future<bool> _refreshOnce() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final f = Future(() async {
      try {
        return await refresh!();
      } catch (_) {
        return false;
      }
    });
    _inFlight = f;
    f.whenComplete(() => _inFlight = null);
    return f;
  }
}
