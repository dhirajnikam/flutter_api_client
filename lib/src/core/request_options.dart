import 'cancel_token.dart';
import 'response_type.dart';

/// Callback used for upload / download progress.
typedef ProgressCallback = void Function(int count, int? total);

/// Per-request options.
///
/// All fields override values from [ApiClientConfig] for this single
/// request only.
class RequestOptions {
  const RequestOptions({
    this.headers,
    this.queryParameters,
    this.timeout,
    this.baseUrlOverride,
    this.includeToken = true,
    this.extraHeaders = const {},
    this.responseType = ResponseType.json,
    this.cancelToken,
    this.onSendProgress,
    this.onReceiveProgress,
    this.retryPolicy,
    this.cachePolicy,
    this.tag,
  });

  /// Override or extra headers for this request.
  final Map<String, String>? headers;

  /// Query parameters appended to the URL.
  final Map<String, dynamic>? queryParameters;

  /// Override request timeout.
  final Duration? timeout;

  /// Override base URL.
  final String? baseUrlOverride;

  /// Whether to attach the auth token. Defaults to true.
  final bool includeToken;

  /// Extra headers merged after `headers` (lower precedence).
  final Map<String, String> extraHeaders;

  /// Desired body decoding mode.
  final ResponseType responseType;

  /// Token used to cancel the request.
  final CancelToken? cancelToken;

  /// Called as request body bytes are sent.
  final ProgressCallback? onSendProgress;

  /// Called as response body bytes are received.
  final ProgressCallback? onReceiveProgress;

  /// Override retry policy for this request.
  /// Pass a [RetryPolicy] from `package:flutter_api_client/flutter_api_client.dart`.
  /// Typed as [Object?] to avoid a circular import between core and interceptors.
  final Object? retryPolicy;

  /// Override cache policy for this request.
  /// Pass a [CachePolicy] from `package:flutter_api_client/flutter_api_client.dart`.
  /// Typed as [Object?] to avoid a circular import between core and interceptors.
  final Object? cachePolicy;

  /// Arbitrary tag for interceptors to inspect.
  final Object? tag;

  RequestOptions copyWith({
    Map<String, String>? headers,
    Map<String, dynamic>? queryParameters,
    Duration? timeout,
    String? baseUrlOverride,
    bool? includeToken,
    Map<String, String>? extraHeaders,
    ResponseType? responseType,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    Object? retryPolicy,
    Object? cachePolicy,
    Object? tag,
  }) => RequestOptions(
    headers: headers ?? this.headers,
    queryParameters: queryParameters ?? this.queryParameters,
    timeout: timeout ?? this.timeout,
    baseUrlOverride: baseUrlOverride ?? this.baseUrlOverride,
    includeToken: includeToken ?? this.includeToken,
    extraHeaders: extraHeaders ?? this.extraHeaders,
    responseType: responseType ?? this.responseType,
    cancelToken: cancelToken ?? this.cancelToken,
    onSendProgress: onSendProgress ?? this.onSendProgress,
    onReceiveProgress: onReceiveProgress ?? this.onReceiveProgress,
    retryPolicy: retryPolicy ?? this.retryPolicy,
    cachePolicy: cachePolicy ?? this.cachePolicy,
    tag: tag ?? this.tag,
  );
}
