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

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    if (!req.options.includeToken) return ProceedResult(req);
    final token = await storage.getAccessToken();
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] =
          authScheme.isEmpty ? token : '$authScheme $token';
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
    if ((req.headers['x-fac-retried-auth'] ?? '') == '1') {
      return ResolveResult(res);
    }
    final ok = await _refreshOnce();
    if (!ok) return ResolveResult(res);
    final retry = req.copy();
    retry.headers['x-fac-retried-auth'] = '1';
    return ProceedResult(retry);
  }

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
