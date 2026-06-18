/// Typed exceptions used throughout the API client.
///
/// All errors surfaced by [ApiClient] derive from [ApiException]. Use
/// `switch` on a sealed instance for exhaustive handling.
sealed class ApiException implements Exception {
  const ApiException(this.message, {this.cause, this.stackTrace});

  /// Human readable error message.
  final String message;

  /// Underlying error if any.
  final Object? cause;

  /// Stack trace captured when the exception was created.
  final StackTrace? stackTrace;

  @override
  String toString() => '$runtimeType: $message';
}

/// Low level I/O / DNS / socket failure.
final class NetworkError extends ApiException {
  const NetworkError(super.message, {super.cause, super.stackTrace});
}

/// Request exceeded its [Duration] timeout.
final class TimeoutError extends ApiException {
  const TimeoutError(super.message, {super.cause, super.stackTrace});
}

/// Request was cancelled by the caller via a [CancelToken].
final class CancelError extends ApiException {
  const CancelError([super.message = 'Request cancelled']);
}

/// Server returned a non 2xx status code.
final class HttpError extends ApiException {
  const HttpError(
    super.message, {
    required this.statusCode,
    this.body,
    this.headers = const {},
    super.cause,
    super.stackTrace,
  });

  /// The non-2xx status code the server returned.
  final int statusCode;

  /// The decoded error body, if any (shape depends on the response).
  final dynamic body;

  /// The response headers.
  final Map<String, String> headers;
}

/// Failed to decode the response body.
final class ParseError extends ApiException {
  const ParseError(super.message, {super.cause, super.stackTrace});
}

/// Request or response payload exceeded a configured byte limit.
final class PayloadTooLargeError extends ApiException {
  const PayloadTooLargeError(
    super.message, {
    this.limitBytes,
    this.actualBytes,
    this.direction,
    super.cause,
    super.stackTrace,
  });

  /// The configured byte limit that was exceeded.
  final int? limitBytes;

  /// The actual size in bytes that tripped the limit.
  final int? actualBytes;

  /// Which body exceeded the limit: `'request'` or `'response'`.
  final String? direction;
}

/// Catch-all for anything else.
final class UnknownError extends ApiException {
  const UnknownError(super.message, {super.cause, super.stackTrace});
}
