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

  String method;
  String endpoint;
  Map<String, String> headers;
  RequestOptions options;
  dynamic data;
  bool isMultipart;

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

final class ProceedResult extends InterceptorResult {
  const ProceedResult(this.request);
  final InterceptedRequest request;
}

final class ResolveResult extends InterceptorResult {
  const ResolveResult(this.response);
  final AdapterResponse response;
}

final class RejectResult extends InterceptorResult {
  const RejectResult(this.error);
  final ApiException error;
}

/// Base interceptor. Override the hooks you need.
abstract class Interceptor {
  const Interceptor();

  Future<InterceptorResult> onRequest(InterceptedRequest req) async =>
      ProceedResult(req);

  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async =>
      ResolveResult(res);

  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async =>
      RejectResult(error);
}
