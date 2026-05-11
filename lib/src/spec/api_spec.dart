import 'examples.dart';
import 'graphql_spec.dart';
import 'schema.dart';

/// A single endpoint in the spec.
class EndpointSpec {
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

  final String method;

  /// Path with `{paramName}` placeholders, e.g. `/users/{id}`.
  final String path;

  final String? summary;
  final String? description;
  final String? tag;
  final bool auth;
  final Map<String, Schema> pathParams;
  final Map<String, Schema> queryParams;
  final RequestExample? request;
  final List<ResponseExample> responses;

  ResponseExample? get firstSuccess => responses
      .where((r) => r.isSuccess)
      .cast<ResponseExample?>()
      .firstWhere((_) => true, orElse: () => null);

  /// Compiles `path` into a regex matcher (e.g. `/users/(.+?)`).
  RegExp get pathPattern {
    final escaped = path.replaceAllMapped(
      RegExp(r'\{([^}]+)\}'),
      (_) => r'([^/]+)',
    );
    return RegExp('^$escaped\$');
  }

  List<String> get pathParamNames {
    final out = <String>[];
    final re = RegExp(r'\{([^}]+)\}');
    for (final m in re.allMatches(path)) {
      out.add(m.group(1)!);
    }
    return out;
  }
}

/// A spec is the source of truth: it drives mocks, OpenAPI, and docs.
class ApiSpec {
  ApiSpec({
    required this.title,
    required this.version,
    required this.baseUrl,
    this.description,
    this.servers = const [],
    this.contact,
    this.license,
  });

  final String title;
  final String version;
  final String baseUrl;
  final String? description;
  final List<String> servers;
  final Map<String, String>? contact;
  final Map<String, String>? license;

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
  }) => _spec.endpoint(
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
