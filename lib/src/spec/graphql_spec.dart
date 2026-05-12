import 'schema.dart';

/// Kind of GraphQL operation.
enum GraphQLOperationKind { query, mutation, subscription }

/// Example of a GraphQL error to include in docs / mocks.
class GraphQLErrorExample {
  const GraphQLErrorExample({
    required this.message,
    this.path,
    this.extensions,
  });

  final String message;
  final List<Object>? path;
  final Map<String, Object?>? extensions;

  Map<String, Object?> toJson() => {
        'message': message,
        if (path != null) 'path': path,
        if (extensions != null) 'extensions': extensions,
      };
}

/// A single GraphQL operation declaration in an [ApiSpec].
class GraphQLOperation {
  const GraphQLOperation({
    required this.name,
    required this.kind,
    required this.document,
    this.description,
    this.tag,
    this.auth = true,
    this.variables = const {},
    this.responseExample,
    this.responseSchema,
    this.errors = const [],
  });

  final String name;
  final GraphQLOperationKind kind;

  /// The query document. Pass the full `query Foo($x: Int!) { ... }` text.
  final String document;

  final String? description;
  final String? tag;
  final bool auth;

  /// Variable name -> schema.
  final Map<String, Schema> variables;

  /// Example payload for the `data` field of the response.
  final Object? responseExample;

  /// Optional schema for the `data` field.
  final Schema? responseSchema;

  /// Sample errors that may be returned for this operation.
  final List<GraphQLErrorExample> errors;

  bool get isQuery => kind == GraphQLOperationKind.query;
  bool get isMutation => kind == GraphQLOperationKind.mutation;
  bool get isSubscription => kind == GraphQLOperationKind.subscription;
}

/// GraphQL section of an [ApiSpec]. Contains the HTTP path the gateway is
/// served at plus a list of [GraphQLOperation]s.
class GraphQLSection {
  GraphQLSection({this.endpoint = '/graphql', this.description});

  String endpoint;
  String? description;
  final List<GraphQLOperation> operations = [];

  void operation(
    String name, {
    required GraphQLOperationKind kind,
    required String document,
    String? description,
    String? tag,
    bool auth = true,
    Map<String, Schema> variables = const {},
    Object? responseExample,
    Schema? responseSchema,
    List<GraphQLErrorExample> errors = const [],
  }) {
    operations.add(
      GraphQLOperation(
        name: name,
        kind: kind,
        document: document,
        description: description,
        tag: tag,
        auth: auth,
        variables: variables,
        responseExample: responseExample,
        responseSchema: responseSchema,
        errors: errors,
      ),
    );
  }

  void query(
    String name, {
    required String document,
    String? description,
    String? tag,
    bool auth = true,
    Map<String, Schema> variables = const {},
    Object? responseExample,
    Schema? responseSchema,
    List<GraphQLErrorExample> errors = const [],
  }) =>
      operation(
        name,
        kind: GraphQLOperationKind.query,
        document: document,
        description: description,
        tag: tag,
        auth: auth,
        variables: variables,
        responseExample: responseExample,
        responseSchema: responseSchema,
        errors: errors,
      );

  void mutation(
    String name, {
    required String document,
    String? description,
    String? tag,
    bool auth = true,
    Map<String, Schema> variables = const {},
    Object? responseExample,
    Schema? responseSchema,
    List<GraphQLErrorExample> errors = const [],
  }) =>
      operation(
        name,
        kind: GraphQLOperationKind.mutation,
        document: document,
        description: description,
        tag: tag,
        auth: auth,
        variables: variables,
        responseExample: responseExample,
        responseSchema: responseSchema,
        errors: errors,
      );
}
