import 'api_exception.dart';

/// Sealed result type returned by all API calls.
///
/// Simple usage — check [isSuccess], read [data] or [errorMessage]:
/// ```dart
/// final result = await client.get<User>('users/me', decoder: User.fromJson);
/// if (result.isSuccess) {
///   print(result.data!.name);
/// } else {
///   showSnackbar(result.errorMessage!);
/// }
/// ```
///
/// Typed error handling — use [when] with a sealed switch:
/// ```dart
/// result.when(
///   success: (user) => updateState(user),
///   failure: (err) => switch (err) {
///     HttpError(statusCode: 401) => logout(),
///     NetworkError()             => showOfflineBanner(),
///     _                          => showSnackbar(err.message),
///   },
/// );
/// ```
sealed class ApiResult<T> {
  const ApiResult();

  /// True when this is a [Success].
  bool get isSuccess => this is Success<T>;

  /// True when this is a [Failure].
  bool get isFailure => this is Failure<T>;

  /// The decoded response body. Non-null on [Success], null on [Failure].
  T? get data => switch (this) {
        Success<T>(:final data) => data,
        Failure<T>() => null,
      };

  /// The typed error. Non-null on [Failure], null on [Success].
  ApiException? get error => switch (this) {
        Success<T>() => null,
        Failure<T>(:final error) => error,
      };

  /// Human-readable error string. Shorthand for [error]?.message.
  String? get errorMessage => error?.message;

  /// Alias for [data]. Returns the success value or null.
  T? get dataOrNull => data;

  /// Alias for [error]. Returns the typed error or null.
  ApiException? get errorOrNull => error;

  /// HTTP status code. Present on both branches where available.
  int? get statusCode => switch (this) {
        Success<T>(:final statusCode) => statusCode,
        Failure<T>() => null,
      };

  /// Response headers.
  ///
  /// On [Success] these are the response headers. On [Failure] they are
  /// surfaced from [HttpError.headers] when the failure carried an HTTP
  /// response (so header data is not silently dropped); for transport-level
  /// failures with no response, an empty map.
  Map<String, String> get headers => switch (this) {
        Success<T>(:final headers) => headers,
        Failure<T>(:final error) =>
          error is HttpError ? error.headers : const {},
      };

  /// Pattern match success / failure exhaustively.
  R when<R>({
    required R Function(T data) success,
    required R Function(ApiException error) failure,
  }) =>
      switch (this) {
        Success<T>(:final data) => success(data),
        Failure<T>(:final error) => failure(error),
      };

  /// Map the success value to another type, passing failure through unchanged.
  ApiResult<R> map<R>(R Function(T data) transform) => switch (this) {
        Success<T>(:final data, :final statusCode, :final headers) =>
          Success<R>(
            transform(data),
            statusCode: statusCode,
            headers: headers,
          ),
        Failure<T>(:final error, :final statusCode) => Failure<R>(
            error,
            statusCode: statusCode,
          ),
      };
}

/// Successful API result carrying the decoded body.
final class Success<T> extends ApiResult<T> {
  const Success(this.data, {required this.statusCode, this.headers = const {}});

  @override
  final T data;

  @override
  final int statusCode;

  @override
  final Map<String, String> headers;
}

/// Failed API result carrying a typed [ApiException].
final class Failure<T> extends ApiResult<T> {
  const Failure(this.error, {int? statusCode})
      : _explicitStatusCode = statusCode;

  @override
  final ApiException error;

  final int? _explicitStatusCode;

  /// HTTP status code. Falls back to [HttpError.statusCode] when not set explicitly.
  @override
  int? get statusCode {
    if (_explicitStatusCode != null) return _explicitStatusCode;
    final err = error;
    if (err is HttpError) return err.statusCode;
    return null;
  }
}
