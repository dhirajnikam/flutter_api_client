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
    this.bodyStream,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
  final String? reasonPhrase;

  /// When non-null, the body has not been buffered into [bodyBytes] and is
  /// instead available as a live byte stream. Produced by [HttpAdapter.sendStreaming].
  final Stream<List<int>>? bodyStream;
}

/// Pluggable transport. Swap out [DefaultHttpAdapter] for `cupertino_http`,
/// `cronet_http`, or a [MockAdapter] in tests.
abstract class HttpAdapter {
  Future<AdapterResponse> send(AdapterRequest request);

  /// Releases any persistent resources.
  void close();
}

/// Optional capability an [HttpAdapter] may also implement to return an
/// unbuffered response body via [AdapterResponse.bodyStream].
///
/// Kept separate from [HttpAdapter] so adding streaming never breaks existing
/// adapters that `implements HttpAdapter`. `ApiClient.stream` uses it when the
/// configured adapter provides it, and otherwise falls back to buffering.
abstract interface class StreamingHttpAdapter {
  Future<AdapterResponse> sendStreaming(AdapterRequest request);
}
