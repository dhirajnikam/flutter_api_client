import 'examples.dart';
import 'graphql_spec.dart';
import 'schema.dart';

/// A single endpoint in the spec.
class EndpointSpec {
  /// Creates an endpoint. Prefer [ApiSpec.endpoint] / [EndpointGroup.endpoint]
  /// over calling this directly.
  EndpointSpec({
    required this.method,
    required this.path,
    this.summary,
    this.description,
    this.tag,
    this.auth = true,
    this.pathParams = const {},
    this.queryParams = const {},
    this.request,
    this.responses = const [],
  });

  /// Uppercase HTTP method, e.g. `GET` or `POST`.
  final String method;

  /// Path with `{paramName}` placeholders, e.g. `/users/{id}`.
  final String path;

  /// One-line summary shown in generated docs.
  final String? summary;

  /// Longer prose description shown in generated docs.
  final String? description;

  /// Grouping tag; endpoints sharing a tag are documented together.
  final String? tag;

  /// Whether this endpoint requires an auth token. Defaults to `true`.
  final bool auth;

  /// Schemas for path parameters, keyed by placeholder name.
  final Map<String, Schema> pathParams;

  /// Schemas for query parameters, keyed by parameter name.
  final Map<String, Schema> queryParams;

  /// Example request body and its schema, if the endpoint takes a body.
  final RequestExample? request;

  /// Declared example responses, used to drive mocks and docs.
  final List<ResponseExample> responses;

  /// Matches a `{placeholder}` token in a path. The pattern depends only on the
  /// path syntax, not on any instance, so compile it once and share it.
  static final RegExp _placeholder = RegExp(r'\{([^}]+)\}');

  /// The first 2xx response in [responses], or `null` if none is declared.
  ResponseExample? get firstSuccess {
    for (final r in responses) {
      if (r.isSuccess) return r;
    }
    return null;
  }

  /// Compiles `path` into a regex matcher (e.g. `/users/(.+?)`).
  ///
  /// `path` is immutable, so the compiled pattern is memoized: callers such as
  /// the spec mock adapter probe this once per endpoint per request, and
  /// recompiling a fixed regex on every probe is overhead the problem does not
  /// require.
  RegExp get pathPattern => _pathPattern ??=
      RegExp('^${path.replaceAllMapped(_placeholder, (_) => r'([^/]+)')}\$');
  RegExp? _pathPattern;

  /// The placeholder names in [path], in order (e.g. `['id']` for
  /// `/users/{id}`). Memoized — derived purely from the immutable `path`.
  List<String> get pathParamNames => _pathParamNames ??= [
        for (final m in _placeholder.allMatches(path)) m.group(1)!,
      ];
  List<String>? _pathParamNames;
}

/// A spec is the source of truth: it drives mocks, OpenAPI, and docs.
class ApiSpec {
  /// Creates a spec. Add endpoints with [endpoint] / [group] and an optional
  /// GraphQL section with [graphql].
  ApiSpec({
    required this.title,
    required this.version,
    required this.baseUrl,
    this.description,
    this.servers = const [],
    this.contact,
    this.license,
  });

  /// Human-readable API title.
  final String title;

  /// API version string, e.g. `1.0.0`.
  final String version;

  /// Default server base URL.
  final String baseUrl;

  /// Optional prose description of the API.
  final String? description;

  /// Additional server URLs beyond [baseUrl]; emitted in the OpenAPI document.
  final List<String> servers;

  /// Optional contact metadata (e.g. `{'name': ..., 'email': ...}`).
  final Map<String, String>? contact;

  /// Optional license metadata (e.g. `{'name': ..., 'url': ...}`).
  final Map<String, String>? license;

  /// All registered HTTP endpoints, in declaration order.
  final List<EndpointSpec> endpoints = [];

  /// Optional GraphQL section. Populated lazily via [graphql].
  GraphQLSection? graphqlSection;

  /// Returns the (lazily-created) GraphQL section.
  ///
  /// Example:
  /// ```dart
  /// spec.graphql(endpoint: '/graphql', (g) {
  ///   g.query('Me', document: 'query Me { me { id name } }',
  ///     responseExample: {'me': {'id': 1, 'name': 'A'}});
  /// });
  /// ```
  GraphQLSection graphql(
    void Function(GraphQLSection g) build, {
    String endpoint = '/graphql',
    String? description,
  }) {
    final section = graphqlSection ??= GraphQLSection(
      endpoint: endpoint,
      description: description,
    );
    section.endpoint = endpoint;
    if (description != null) section.description = description;
    build(section);
    return section;
  }

  /// Adds a group of endpoints under a common tag.
  void group(String tag, void Function(EndpointGroup g) build) {
    build(EndpointGroup(this, tag));
  }

  /// Adds a single endpoint. Pass `'POST /auth/login'` style.
  EndpointSpec endpoint(
    String methodAndPath, {
    String? summary,
    String? description,
    String? tag,
    bool auth = true,
    Map<String, Schema> pathParams = const {},
    Map<String, Schema> queryParams = const {},
    RequestExample? request,
    ResponseExample? response,
    List<ResponseExample>? responses,
  }) {
    final parts = methodAndPath.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) {
      throw ArgumentError('Expected "METHOD /path", got "$methodAndPath"');
    }
    final ep = EndpointSpec(
      method: parts[0].toUpperCase(),
      path: parts[1],
      summary: summary,
      description: description,
      tag: tag,
      auth: auth,
      pathParams: pathParams,
      queryParams: queryParams,
      request: request,
      responses: [if (response != null) response, ...?responses],
    );
    endpoints.add(ep);
    return ep;
  }
}

/// Fluent helper passed to [ApiSpec.group].
class EndpointGroup {
  EndpointGroup(this._spec, this._tag);
  final ApiSpec _spec;
  final String _tag;

  EndpointSpec endpoint(
    String methodAndPath, {
    String? summary,
    String? description,
    bool auth = true,
    Map<String, Schema> pathParams = const {},
    Map<String, Schema> queryParams = const {},
    RequestExample? request,
    ResponseExample? response,
    List<ResponseExample>? responses,
  }) =>
      _spec.endpoint(
        methodAndPath,
        summary: summary,
        description: description,
        tag: _tag,
        auth: auth,
        pathParams: pathParams,
        queryParams: queryParams,
        request: request,
        response: response,
        responses: responses,
      );
}
