import 'schema.dart';

/// Kind of GraphQL operation.
enum GraphQLOperationKind {
  /// A read operation (`query`).
  query,

  /// A write operation (`mutation`).
  mutation,

  /// A streaming operation (`subscription`).
  subscription,
}

/// Example of a GraphQL error to include in docs / mocks.
class GraphQLErrorExample {
  /// Creates an error example.
  const GraphQLErrorExample({
    required this.message,
    this.path,
    this.extensions,
  });

  /// Human-readable error message.
  final String message;

  /// Response path to the errored field, e.g. `['user', 'name']`.
  final List<Object>? path;

  /// Server-defined metadata; the error code conventionally lives under
  /// `extensions['code']`.
  final Map<String, Object?>? extensions;

  /// Serializes to the GraphQL `errors[]` entry shape.
  Map<String, Object?> toJson() => {
        'message': message,
        if (path != null) 'path': path,
        if (extensions != null) 'extensions': extensions,
      };
}

/// A single GraphQL operation declaration in an `ApiSpec`.
class GraphQLOperation {
  /// Creates an operation declaration. Prefer [GraphQLSection.query] /
  /// [GraphQLSection.mutation] / [GraphQLSection.operation].
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

  /// Operation name, e.g. `Me` in `query Me { ... }`.
  final String name;

  /// Whether this is a query, mutation, or subscription.
  final GraphQLOperationKind kind;

  /// The query document. Pass the full `query Foo($x: Int!) { ... }` text.
  final String document;

  /// Optional prose description shown in generated docs.
  final String? description;

  /// Grouping tag for generated docs.
  final String? tag;

  /// Whether this operation requires an auth token. Defaults to `true`.
  final bool auth;

  /// Variable name -> schema.
  final Map<String, Schema> variables;

  /// Example payload for the `data` field of the response.
  final Object? responseExample;

  /// Optional schema for the `data` field.
  final Schema? responseSchema;

  /// Sample errors that may be returned for this operation.
  final List<GraphQLErrorExample> errors;

  /// Whether [kind] is [GraphQLOperationKind.query].
  bool get isQuery => kind == GraphQLOperationKind.query;

  /// Whether [kind] is [GraphQLOperationKind.mutation].
  bool get isMutation => kind == GraphQLOperationKind.mutation;

  /// Whether [kind] is [GraphQLOperationKind.subscription].
  bool get isSubscription => kind == GraphQLOperationKind.subscription;
}

/// GraphQL section of an `ApiSpec`. Contains the HTTP path the gateway is
/// served at plus a list of [GraphQLOperation]s.
class GraphQLSection {
  /// Creates a section served at [endpoint] (HTTP `POST`).
  GraphQLSection({this.endpoint = '/graphql', this.description});

  /// HTTP path the GraphQL gateway is served at.
  String endpoint;

  /// Optional prose description shown in generated docs.
  String? description;

  /// Declared operations, in declaration order.
  final List<GraphQLOperation> operations = [];

  /// Declares an operation of any [kind]. [query] and [mutation] are
  /// shorthands for the common kinds.
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

  /// Declares a [GraphQLOperationKind.query] operation; see [operation].
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

  /// Declares a [GraphQLOperationKind.mutation] operation; see [operation].
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
