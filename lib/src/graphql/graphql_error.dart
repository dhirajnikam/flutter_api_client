/// A single error returned in the `errors` array of a GraphQL response.
class GraphQLError {
  const GraphQLError({
    required this.message,
    this.path,
    this.locations,
    this.extensions,
  });

  final String message;

  /// Response path to the field that errored, e.g. `['user', 'name']`.
  final List<Object>? path;

  /// Source locations in the query document, each a `{line, column}` map.
  final List<Map<String, Object?>>? locations;

  /// Server-defined error metadata. The conventional error code lives under
  /// `extensions['code']`.
  final Map<String, Object?>? extensions;

  /// Parses one entry of a GraphQL response `errors` array. Falls back to a
  /// generic message when the `message` field is missing.
  factory GraphQLError.fromJson(Map<String, Object?> json) => GraphQLError(
        message: json['message']?.toString() ?? 'Unknown GraphQL error',
        path:
            json['path'] is List ? (json['path'] as List).cast<Object>() : null,
        locations:
            (json['locations'] as List?)?.cast<Map<String, Object?>>().toList(),
        extensions: (json['extensions'] as Map?)?.cast<String, Object?>(),
      );

  @override
  String toString() =>
      'GraphQLError($message${path == null ? '' : ' at $path'})';
}

/// Thrown / surfaced when a GraphQL response contains `errors`.
@Deprecated(
  'Never thrown by this package; read GraphQLResponse.errors. To '
  'be removed in 2.0.0.',
)
class GraphQLException implements Exception {
  GraphQLException(this.errors);

  final List<GraphQLError> errors;

  /// The first error's message, or a generic message when [errors] is empty.
  String get message => errors.isEmpty ? 'GraphQL error' : errors.first.message;

  @override
  String toString() => 'GraphQLException: $message';
}
