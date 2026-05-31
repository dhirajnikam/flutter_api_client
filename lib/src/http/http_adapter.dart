import 'dart:typed_data';

import '../core/cancel_token.dart';
import '../core/form_data.dart';
import '../core/request_options.dart';

/// Low-level request passed to an [HttpAdapter].
class AdapterRequest {
  AdapterRequest({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
    this.formData,
    this.isMultipart = false,
    required this.timeout,
    this.cancelToken,
    this.onSendProgress,
    this.onReceiveProgress,
    this.maxRequestBodyBytes,
    this.maxResponseBodyBytes,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// Raw bytes or string body (already encoded). Mutually exclusive with
  /// [formData].
  final Object? body;
  final FormData? formData;
  final bool isMultipart;
  final Duration timeout;
  final CancelToken? cancelToken;
  final ProgressCallback? onSendProgress;
  final ProgressCallback? onReceiveProgress;

  final int? maxRequestBodyBytes;
  final int? maxResponseBodyBytes;
}

/// Low-level response returned by an [HttpAdapter].
class AdapterResponse {
  AdapterResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    this.reasonPhrase,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
  final String? reasonPhrase;
}

/// Pluggable transport. Swap out [DefaultHttpAdapter] for `cupertino_http`,
/// `cronet_http`, or a [MockAdapter] in tests.
abstract class HttpAdapter {
  Future<AdapterResponse> send(AdapterRequest request);

  /// Releases any persistent resources.
  void close();
}
