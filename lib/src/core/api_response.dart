/// Standard API response wrapper for consistent handling across calls.
///
/// In 1.0.0 this type is generic. For backwards compatibility, omitting
/// the type parameter defaults to `dynamic` which preserves the prior
/// behaviour of returning decoded JSON as `dynamic`.
class CustomApiResponse<T> {
  CustomApiResponse({
    required this.statusCode,
    required this.headers,
    required this.data,
    required this.isSuccess,
    this.errorMessage,
    this.rawBody,
  });

  /// Parsed response body, or null.
  final T? data;

  /// Error message when [isSuccess] is false.
  final String? errorMessage;

  /// Response headers.
  final Map<String, String> headers;

  /// True for any 2xx status code.
  final bool isSuccess;

  /// HTTP status code.
  final int statusCode;

  /// Raw body bytes (always populated).
  final List<int>? rawBody;
}
