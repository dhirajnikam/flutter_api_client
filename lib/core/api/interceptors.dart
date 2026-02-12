import 'package:http/http.dart' as http;

import 'custom_api_response.dart';

/// Intercepts a request before it is sent.
/// Return modified [headers] and [data] (or null to keep original).
class RequestInterceptor {
  const RequestInterceptor();

  /// Called before each request. Modify and return the request data.
  /// Return [InterceptedRequest] with optional overrides.
  Future<InterceptedRequest> onRequest(
    String method,
    String endpoint, {
    dynamic data,
    Map<String, String>? headers,
    bool isMultipart = false,
  }) async => InterceptedRequest(
    method: method,
    endpoint: endpoint,
    data: data,
    headers: headers,
    isMultipart: isMultipart,
  );
}

/// Result of [RequestInterceptor.onRequest]. Use to override request parts.
class InterceptedRequest {
  const InterceptedRequest({
    required this.method,
    required this.endpoint,
    this.data,
    this.headers,
    this.isMultipart = false,
  });

  final String method;
  final String endpoint;
  final dynamic data;
  final Map<String, String>? headers;
  final bool isMultipart;
}

/// Intercepts a response after it is received.
/// Return modified [CustomApiResponse] or null to keep original.
class ResponseInterceptor {
  const ResponseInterceptor();

  /// Called after each response. Modify and return the response.
  Future<CustomApiResponse?> onResponse(
    http.Response rawResponse,
    CustomApiResponse parsedResponse,
  ) async => null;
}
