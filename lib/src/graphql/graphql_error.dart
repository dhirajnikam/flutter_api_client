/// A single error returned in the `errors` array of a GraphQL response.
class GraphQLError {
  const GraphQLError({
    required this.message,
    this.path,
    this.locations,
    this.extensions,
  });

  final String message;
  final List<Object>? path;
  final List<Map<String, Object?>>? locations;
  final Map<String, Object?>? extensions;

  factory GraphQLError.fromJson(Map<String, Object?> json) => GraphQLError(
    message: json['message']?.toString() ?? 'Unknown GraphQL error',
    path: json['path'] is List ? (json['path'] as List).cast<Object>() : null,
    locations: (json['locations'] as List?)
        ?.cast<Map<String, Object?>>()
        .toList(),
    extensions: (json['extensions'] as Map?)?.cast<String, Object?>(),
  );

  @override
  String toString() =>
      'GraphQLError($message${path == null ? '' : ' at $path'})';
}

/// Thrown / surfaced when a GraphQL response contains `errors`.
class GraphQLException implements Exception {
  GraphQLException(this.errors);

  final List<GraphQLError> errors;

  String get message => errors.isEmpty ? 'GraphQL error' : errors.first.message;

  @override
  String toString() => 'GraphQLException: $message';
}
