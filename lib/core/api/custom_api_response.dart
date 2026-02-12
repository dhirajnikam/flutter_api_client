/// Standard API response wrapper for consistent handling across calls.
class CustomApiResponse {
  CustomApiResponse({
    required this.statusCode,
    required this.headers,
    required this.data,
    required this.isSuccess,
    this.errorMessage,
  });

  final dynamic data;
  final String? errorMessage;
  final Map<String, String> headers;
  final bool isSuccess;
  final int statusCode;
}
