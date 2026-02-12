/// Per-request options to override defaults.
///
/// Use this to customize individual requests without changing the client config.
class RequestOptions {
  const RequestOptions({
    this.headers,
    this.timeout,
    this.baseUrlOverride,
    this.includeToken = true,
    this.extraHeaders = const {},
  });

  /// Additional or override headers for this request.
  final Map<String, String>? headers;

  /// Request timeout. Overrides default from config.
  final Duration? timeout;

  /// Override base URL for this request (e.g. for CDN or different API).
  final String? baseUrlOverride;

  /// Whether to include auth token. Defaults to true.
  final bool includeToken;

  /// Extra headers merged with request headers.
  final Map<String, String> extraHeaders;

  RequestOptions copyWith({
    Map<String, String>? headers,
    Duration? timeout,
    String? baseUrlOverride,
    bool? includeToken,
    Map<String, String>? extraHeaders,
  }) => RequestOptions(
    headers: headers ?? this.headers,
    timeout: timeout ?? this.timeout,
    baseUrlOverride: baseUrlOverride ?? this.baseUrlOverride,
    includeToken: includeToken ?? this.includeToken,
    extraHeaders: extraHeaders ?? this.extraHeaders,
  );
}
