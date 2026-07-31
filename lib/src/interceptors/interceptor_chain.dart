import '../core/api_exception.dart';
import '../http/http_adapter.dart';
import 'interceptor.dart';

/// The terminal network call the chain wraps: sends [req] and yields a
/// response (or throws an [ApiException]).
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
  /// Wraps [interceptors], run in list order on the request side and in
  /// reverse on the response/error side.
  InterceptorChain(this.interceptors);

  /// The interceptors this chain coordinates.
  final List<Interceptor> interceptors;

  static const _depthExceeded = UnknownError('Interceptor retry depth exceeded');

  /// Runs [request] through the chain and [transport], returning the final
  /// response or throwing the final [ApiException].
  ///
  /// [retryDepth] tracks chain restarts (from a [ProceedResult] on the
  /// response/error side) and is bounded to prevent infinite retry loops.
  Future<AdapterResponse> run({
    required InterceptedRequest request,
    required Transport transport,
    int retryDepth = 0,
  }) async {
    if (retryDepth > 8) {
      // Don't throw past the interceptors: give them one onError pass so they
      // can clean up per-request state (e.g. dedup must release its in-flight
      // entry or every future identical request stalls on a dead leader).
      // Proceeding is disabled on this pass so the chain cannot restart and
      // recurse back here.
      return _handleError(
        request,
        transport,
        retryDepth,
        _depthExceeded,
        allowProceed: false,
      );
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
    int retryDepth, {
    bool allowProceed = true,
  }) async {
    AdapterResponse current = res;
    for (final i in interceptors.reversed) {
      InterceptorResult r;
      try {
        r = await i.onResponse(req, current);
      } catch (e, st) {
        await _discard(current);
        if (!allowProceed) throw _wrap(e, st);
        return _handleError(req, transport, retryDepth, _wrap(e, st));
      }
      switch (r) {
        case ResolveResult(:final response):
          // The old response is discarded when it is replaced; drain its body
          // stream (unless the replacement reuses it) or the adapter's owned
          // client is never released (cleanup runs from controller.done).
          if (!identical(response, current) &&
              current.bodyStream != null &&
              !identical(response.bodyStream, current.bodyStream)) {
            await _discard(current);
          }
          current = response;
        case RejectResult(:final error):
          await _discard(current);
          if (!allowProceed) throw error;
          return _handleError(req, transport, retryDepth, error);
        case ProceedResult(:final request):
          // Restart the chain with the (possibly mutated) request. The
          // current response is discarded, so drain it first.
          await _discard(current);
          if (!allowProceed) throw _depthExceeded;
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
    ApiException error, {
    bool allowProceed = true,
  }) async {
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
          return _afterResponse(
            req,
            response,
            transport,
            retryDepth,
            allowProceed: allowProceed,
          );
        case ProceedResult(:final request):
          if (allowProceed) {
            return run(
              request: request,
              transport: transport,
              retryDepth: retryDepth + 1,
            );
          }
        // Depth exceeded: this is a cleanup-only pass, so a proceed must not
        // restart the chain. Keep the current error and let the remaining
        // interceptors clean up too.
        case RejectResult(:final error):
          current = error;
      }
    }
    throw current;
  }

  /// Drains the body stream of a response that is being discarded, so the
  /// adapter behind it can release its resources. Errors (including an
  /// already-listened stream) are swallowed: the response is dead either way.
  Future<void> _discard(AdapterResponse res) async {
    final stream = res.bodyStream;
    if (stream == null) return;
    try {
      await stream.drain<void>();
    } catch (_) {}
  }

  ApiException _wrap(Object e, StackTrace st) => e is ApiException
      ? e
      : UnknownError(e.toString(), cause: e, stackTrace: st);
}
