import 'dart:async';

import '../../core/api_exception.dart';
import '../../core/query.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';

/// Coalesces identical in-flight GET requests so the network is only hit
/// once. Other matching callers receive the same response.
class DedupInterceptor extends Interceptor {
  DedupInterceptor({this.methods = const {'GET', 'HEAD'}});

  final Set<String> methods;
  final Map<String, Completer<AdapterResponse>> _inFlight = {};
  static const _keyHeader = 'x-fac-dedup-key';

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    if (!methods.contains(req.method.toUpperCase())) return ProceedResult(req);
    final key = _key(req);
    final existing = _inFlight[key];
    if (existing != null) {
      final res = await existing.future;
      return ResolveResult(res);
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
      if (c != null && !c.isCompleted) c.complete(res);
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

  String _key(InterceptedRequest req) {
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? '',
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    ).toString();
    return '${req.method.toUpperCase()} $url';
  }
}
