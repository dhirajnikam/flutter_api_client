import '../core/api_exception.dart';
import 'graphql_error.dart';

/// Result of a GraphQL operation. Carries `data`, any `errors`, and the
/// underlying HTTP status code.
class GraphQLResponse<T> {
  /// Creates a response. Prefer obtaining instances from `GraphQLClient`
  /// rather than constructing them directly.
  GraphQLResponse({
    required this.statusCode,
    required this.data,
    required this.errors,
    required this.isSuccess,
    this.networkError,
    this.extensions,
  });

  /// Decoded `data` field. May be null even on success if the operation
  /// returned no fields.
  final T? data;

  /// List of GraphQL errors. Empty if the operation fully succeeded.
  final List<GraphQLError> errors;

  /// True when `errors` is empty and no transport error was raised.
  ///
  /// A GraphQL response with both `data` and `errors` is considered a
  /// **partial success**; this flag will be false in that case so the
  /// caller can decide how to react.
  final bool isSuccess;

  /// Underlying HTTP status code.
  final int statusCode;

  /// Transport-level error if the response never arrived.
  final ApiException? networkError;

  /// Top-level `extensions` block (server-defined metadata).
  final Map<String, Object?>? extensions;

  /// True when the response carried at least one GraphQL error.
  bool get hasErrors => errors.isNotEmpty;

  /// True for a partial success: both [data] and [errors] are present.
  bool get isPartial => errors.isNotEmpty && data != null;
}
