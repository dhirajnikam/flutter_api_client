import '../core/api_exception.dart';
import '../http/http_adapter.dart';
import 'interceptor.dart';

typedef Transport = Future<AdapterResponse> Function(InterceptedRequest req);

/// Coordinates the ordered run of [Interceptor]s around the transport call.
///
/// Flow:
///   1. onRequest pre-flight (top → bottom). May short-circuit with a
///      response (skip transport) or an error.
///   2. transport.send(request)
///   3. onResponse post-flight (bottom → top). May replace response or
///      reject with an error.
///   4. onError (bottom → top) may recover with a response, or return a
///      [ProceedResult] to retry the whole chain with a fresh request.
class InterceptorChain {
  InterceptorChain(this.interceptors);

  final List<Interceptor> interceptors;

  Future<AdapterResponse> run({
    required InterceptedRequest request,
    required Transport transport,
    int retryDepth = 0,
  }) async {
    if (retryDepth > 8) {
      throw const UnknownError('Interceptor retry depth exceeded');
    }

    InterceptedRequest current = request;
    for (final i in interceptors) {
      InterceptorResult r;
      try {
        r = await i.onRequest(current);
      } catch (e, st) {
        return _handleError(current, transport, retryDepth, _wrap(e, st));
      }
      switch (r) {
        case ProceedResult(:final request):
          current = request;
        case ResolveResult(:final response):
          return _afterResponse(current, response, transport, retryDepth);
        case RejectResult(:final error):
          return _handleError(current, transport, retryDepth, error);
      }
    }

    AdapterResponse response;
    try {
      response = await transport(current);
    } on ApiException catch (e) {
      return _handleError(current, transport, retryDepth, e);
    } catch (e, st) {
      return _handleError(current, transport, retryDepth, _wrap(e, st));
    }
    return _afterResponse(current, response, transport, retryDepth);
  }

  Future<AdapterResponse> _afterResponse(
    InterceptedRequest req,
    AdapterResponse res,
    Transport transport,
    int retryDepth,
  ) async {
    AdapterResponse current = res;
    for (final i in interceptors.reversed) {
      InterceptorResult r;
      try {
        r = await i.onResponse(req, current);
      } catch (e, st) {
        return _handleError(req, transport, retryDepth, _wrap(e, st));
      }
      switch (r) {
        case ResolveResult(:final response):
          current = response;
        case RejectResult(:final error):
          return _handleError(req, transport, retryDepth, error);
        case ProceedResult(:final request):
          // Restart the chain with the (possibly mutated) request.
          return run(
            request: request,
            transport: transport,
            retryDepth: retryDepth + 1,
          );
      }
    }
    return current;
  }

  Future<AdapterResponse> _handleError(
    InterceptedRequest req,
    Transport transport,
    int retryDepth,
    ApiException error,
  ) async {
    ApiException current = error;
    for (final i in interceptors.reversed) {
      InterceptorResult r;
      try {
        r = await i.onError(req, current);
      } catch (e, st) {
        current = _wrap(e, st);
        continue;
      }
      switch (r) {
        case ResolveResult(:final response):
          return _afterResponse(req, response, transport, retryDepth);
        case ProceedResult(:final request):
          return run(
            request: request,
            transport: transport,
            retryDepth: retryDepth + 1,
          );
        case RejectResult(:final error):
          current = error;
      }
    }
    throw current;
  }

  ApiException _wrap(Object e, StackTrace st) => e is ApiException
      ? e
      : UnknownError(e.toString(), cause: e, stackTrace: st);
}
