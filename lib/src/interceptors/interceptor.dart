import '../core/api_exception.dart';
import '../core/request_options.dart';
import '../http/http_adapter.dart';

/// Fully-resolved request flowing through the interceptor chain.
class InterceptedRequest {
  InterceptedRequest({
    required this.method,
    required this.endpoint,
    required this.headers,
    required this.options,
    this.data,
    this.isMultipart = false,
  });

  /// HTTP method (e.g. `GET`, `POST`).
  String method;

  /// Path or absolute URL being requested, before query resolution.
  String endpoint;

  /// Mutable request headers, including internal `x-fac-*` coordination headers.
  Map<String, String> headers;

  /// Per-request options (query parameters, overrides, timeouts, etc.).
  RequestOptions options;

  /// Request body, if any. `null` for bodyless methods.
  dynamic data;

  /// Whether [data] is a multipart payload (which loggers must not stringify).
  bool isMultipart;

  /// A shallow copy with a fresh [headers] map, so a retry can mutate headers
  /// without disturbing the in-flight request it was cloned from.
  InterceptedRequest copy() => InterceptedRequest(
        method: method,
        endpoint: endpoint,
        headers: Map.of(headers),
        options: options,
        data: data,
        isMultipart: isMultipart,
      );
}

/// Result returned from each step of the chain.
sealed class InterceptorResult {
  const InterceptorResult();
}

/// Continue the chain with [request] (possibly mutated).
final class ProceedResult extends InterceptorResult {
  const ProceedResult(this.request);

  /// The request to carry to the next step.
  final InterceptedRequest request;
}

/// Short-circuit the chain and return [response] without further transport.
final class ResolveResult extends InterceptorResult {
  const ResolveResult(this.response);

  /// The response to resolve with.
  final AdapterResponse response;
}

/// Short-circuit the chain and fail with [error].
final class RejectResult extends InterceptorResult {
  const RejectResult(this.error);

  /// The error to reject with.
  final ApiException error;
}

/// Base interceptor. Override the hooks you need; each defaults to a no-op
/// that simply lets the chain continue.
abstract class Interceptor {
  const Interceptor();

  /// Called before transport, top → bottom. Return a [ProceedResult] to
  /// continue, a [ResolveResult] to short-circuit with a response, or a
  /// [RejectResult] to fail.
  Future<InterceptorResult> onRequest(InterceptedRequest req) async =>
      ProceedResult(req);

  /// Called after a response, bottom → top. May replace the response, reject,
  /// or proceed to restart the chain with a fresh request.
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async =>
      ResolveResult(res);

  /// Called when a step fails, bottom → top. May recover with a response,
  /// proceed to retry the chain, or reject with a (possibly different) error.
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async =>
      RejectResult(error);
}
