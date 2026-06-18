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

  /// HTTP method, already upper-cased.
  final String method;

  /// Fully resolved request URL.
  final Uri url;

  /// Request headers to send as-is.
  final Map<String, String> headers;

  /// Raw bytes or string body (already encoded). Mutually exclusive with
  /// [formData].
  final Object? body;

  /// Multipart payload. Mutually exclusive with [body].
  final FormData? formData;

  /// Whether to send the request as `multipart/form-data`.
  final bool isMultipart;

  /// Deadline for the whole send/receive.
  final Duration timeout;

  /// Token that aborts this request when cancelled.
  final CancelToken? cancelToken;

  /// Called as request body bytes are sent.
  final ProgressCallback? onSendProgress;

  /// Called as response body bytes are received.
  final ProgressCallback? onReceiveProgress;

  /// Reject the request if its encoded body exceeds this many bytes.
  final int? maxRequestBodyBytes;

  /// Reject the response if its body exceeds this many bytes.
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

  /// HTTP status code.
  final int statusCode;

  /// Response headers.
  final Map<String, String> headers;

  /// Buffered response body. Empty when [bodyStream] carries the body instead.
  final Uint8List bodyBytes;

  /// HTTP reason phrase, if the transport reported one.
  final String? reasonPhrase;

  /// When non-null, the body has not been buffered into [bodyBytes] and is
  /// instead available as a live byte stream. Produced by
  /// [StreamingHttpAdapter.sendStreaming].
  final Stream<List<int>>? bodyStream;
}

/// Pluggable transport. Swap out [DefaultHttpAdapter] for `cupertino_http`,
/// `cronet_http`, or a [MockAdapter] in tests.
abstract class HttpAdapter {
  /// Sends [request] and returns the fully buffered response.
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
  /// Sends [request] and returns a response whose body is delivered
  /// incrementally via [AdapterResponse.bodyStream].
  Future<AdapterResponse> sendStreaming(AdapterRequest request);
}
