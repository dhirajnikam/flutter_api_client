/// Standard API response wrapper for consistent handling across calls.
class CustomApiResponse {
  CustomApiResponse({
    required this.statusCode,
    required this.headers,
    required this.data,
    required this.isSuccess,
    this.errorMessage,
  });

  /// Parsed response body (JSON object/array) or null.
  final dynamic data;

  /// Error message when [isSuccess] is false.
  final String? errorMessage;

  /// Response headers.
  final Map<String, String> headers;

  /// True if status code is 200, 201, or 204.
  final bool isSuccess;

  /// HTTP status code.
  final int statusCode;
}
