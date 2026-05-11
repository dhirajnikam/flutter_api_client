import 'api_exception.dart';

/// Sealed result type returned by typed API calls.
///
/// Use [when] for exhaustive handling without null checks.
sealed class ApiResult<T> {
  const ApiResult();

  /// True if this is a [Success].
  bool get isSuccess => this is Success<T>;

  /// True if this is a [Failure].
  bool get isFailure => this is Failure<T>;

  /// Returns the success value or null.
  T? get dataOrNull => switch (this) {
    Success<T>(:final data) => data,
    Failure<T>() => null,
  };

  /// Returns the error or null.
  ApiException? get errorOrNull => switch (this) {
    Success<T>() => null,
    Failure<T>(:final error) => error,
  };

  /// Pattern match success / failure.
  R when<R>({
    required R Function(T data) success,
    required R Function(ApiException error) failure,
  }) => switch (this) {
    Success<T>(:final data) => success(data),
    Failure<T>(:final error) => failure(error),
  };

  /// Map the success value to another type.
  ApiResult<R> map<R>(R Function(T data) transform) => switch (this) {
    Success<T>(:final data, :final statusCode, :final headers) => Success<R>(
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

/// Successful API result.
final class Success<T> extends ApiResult<T> {
  const Success(this.data, {required this.statusCode, this.headers = const {}});

  final T data;
  final int statusCode;
  final Map<String, String> headers;
}

/// Failed API result.
final class Failure<T> extends ApiResult<T> {
  const Failure(this.error, {this.statusCode});

  final ApiException error;
  final int? statusCode;
}
