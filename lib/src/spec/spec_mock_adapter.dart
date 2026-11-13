import 'dart:convert';

import '../http/http_adapter.dart';
import '../http/mock_support.dart';
import 'api_spec.dart';
import 'examples.dart';
import 'graphql_spec.dart';
import 'spec_text.dart';

/// Turns an [ApiSpec] into a fully-working mock adapter.
///
/// Matches by method + path template. Validates the request body against
/// the endpoint's request schema. Returns the first success response by
/// default; pass [statusOverrides] to make endpoints return errors during
/// tests.
class SpecMockAdapter implements HttpAdapter {
  /// Creates a mock adapter that serves responses declared in [spec].
  SpecMockAdapter(
    this.spec, {
    this.latency,
    this.statusOverrides = const {},
    this.validateRequests = true,
  });

  /// The spec whose endpoints and responses are served.
  final ApiSpec spec;

  /// Artificial delay applied to every response, if set.
  final Duration? latency;

  /// Forces a specific status for an endpoint, keyed by `'METHOD /path'` for
  /// HTTP and `'GQL OperationName'` for GraphQL — e.g.
  /// `{ 'POST /auth/login': 401 }`.
  final Map<String, int> statusOverrides;

  /// Whether to validate request bodies and GraphQL variables against their
  /// declared schemas, returning `422` (HTTP) or a `BAD_USER_INPUT` error
  /// (GraphQL) on failure.
  final bool validateRequests;

  /// Every request this adapter has received, in order — useful for
  /// assertions in tests.
  final List<AdapterRequest> received = [];

  @override
  Future<AdapterResponse> send(AdapterRequest req) async {
    received.add(req);
    if (latency != null) await Future.delayed(latency!);
    final path = req.url.path;

    // Route GraphQL traffic first if the spec declares a GraphQL section
    // and the request targets its endpoint.
    final gql = spec.graphqlSection;
    if (gql != null &&
        req.method.toUpperCase() == 'POST' &&
        _matchesGraphqlPath(gql.endpoint, path)) {
      return _serveGraphql(gql, req);
    }

    final match = _match(req.method, path);
    if (match == null) return notFoundResponse('spec endpoint', req);
    if (validateRequests && match.request?.schema != null) {
      // A missing body is validated as an empty object: an endpoint whose
      // schema declares required fields must reject a bodyless request rather
      // than skip validation entirely.
      final body =
          req.body == null ? const <String, Object?>{} : _decodeBody(req);
      final errors = match.request!.schema!.validate(body);
      if (errors.isNotEmpty) {
        return jsonResponse(422, {
          'message': 'Validation failed',
          'errors': errors,
        });
      }
    }

    final overrideStatus = statusOverrides['${match.method} ${match.path}'];
    if (overrideStatus != null) {
      final responses = responsesOrNoContent(match);
      final picked = responses.firstWhere(
        (r) => r.statusCode == overrideStatus,
        orElse: () => responses.first,
      );
      return _toResponse(picked, statusCode: overrideStatus);
    }

    return _toResponse(
      match.firstSuccess ?? responsesOrNoContent(match).first,
    );
  }

  Object? _decodeBody(AdapterRequest req) {
    final b = req.body;
    if (b == null) return null;
    if (b is String) {
      try {
        return jsonDecode(b);
      } catch (_) {
        return b;
      }
    }
    if (b is List<int>) {
      try {
        return jsonDecode(utf8.decode(b));
      } catch (_) {
        return null;
      }
    }
    return b;
  }

  AdapterResponse _toResponse(ResponseExample r, {int? statusCode}) =>
      AdapterResponse(
        statusCode: statusCode ?? r.statusCode,
        headers: Map<String, String>.from(r.headers),
        bodyBytes: encodeMockBody(r.body),
      );

  EndpointSpec? _match(String method, String path) {
    final upper = method.toUpperCase();
    // The base-stripped variant depends only on the request path, not on the
    // endpoint, so compute it once rather than re-parsing spec.baseUrl on every
    // loop iteration.
    final stripped = _stripBase(path);
    final hasStripped = stripped != path;
    // Among matching declarations, prefer the one with the fewest path
    // placeholders so a literal route (`/users/me`) is not swallowed by a
    // templated one declared earlier (`/users/{id}`). Ties keep declaration
    // order: a candidate only replaces the current best when strictly fewer.
    EndpointSpec? best;
    var bestPlaceholders = -1;
    for (final ep in spec.endpoints) {
      if (ep.method != upper) continue;
      final pattern = ep.pathPattern;
      // Also allow the spec base path prefix to be absent.
      final matches =
          pattern.hasMatch(path) || (hasStripped && pattern.hasMatch(stripped));
      if (!matches) continue;
      final placeholders = ep.pathParamNames.length;
      if (best == null || placeholders < bestPlaceholders) {
        best = ep;
        bestPlaceholders = placeholders;
      }
    }
    return best;
  }

  String _stripBase(String path) {
    final basePath = Uri.parse(spec.baseUrl).path;
    if (basePath.isNotEmpty && path.startsWith(basePath)) {
      return path.substring(basePath.length);
    }
    return path;
  }

  bool _matchesGraphqlPath(String declared, String actual) {
    if (declared == actual) return true;
    final stripped = _stripBase(actual);
    if (stripped == declared) return true;
    final norm = declared.startsWith('/') ? declared : '/$declared';
    return actual == norm || stripped == norm;
  }

  Future<AdapterResponse> _serveGraphql(
    GraphQLSection section,
    AdapterRequest req,
  ) async {
    final body = _decodeBody(req);
    if (body is! Map) {
      return _gqlError(400, 'Malformed GraphQL request: expected JSON object');
    }
    final document = body['query'] as String?;
    final operationName = body['operationName'] as String?;
    final extensions = body['extensions'] as Map?;
    final persistedQuery = extensions?['persistedQuery'] as Map?;
    if (document == null && persistedQuery != null) {
      return _gqlResponse(
        200,
        errors: const [
          GraphQLErrorExample(
            message: 'PersistedQueryNotFound',
            extensions: {'code': 'PERSISTED_QUERY_NOT_FOUND'},
          ),
        ],
      );
    }
    if (document == null && operationName == null) {
      return _gqlError(
        400,
        'GraphQL request requires `query` or `operationName`',
      );
    }

    final op = _matchGraphqlOperation(section, operationName, document);
    if (op == null) {
      return _gqlResponse(
        200,
        errors: [
          GraphQLErrorExample(
            message:
                'Operation "${operationName ?? _extractOpName(document)}" not found in spec',
            extensions: const {'code': 'OPERATION_NOT_FOUND'},
          ),
        ],
      );
    }

    if (validateRequests && op.variables.isNotEmpty) {
      final vars = (body['variables'] as Map?)?.cast<String, Object?>() ?? {};
      final problems = <String>[];
      op.variables.forEach((name, schema) {
        problems.addAll(schema.validate(vars[name], name));
      });
      if (problems.isNotEmpty) {
        return _gqlResponse(
          200,
          errors: [
            GraphQLErrorExample(
              message: 'Variable validation failed: ${problems.join('; ')}',
              extensions: const {'code': 'BAD_USER_INPUT'},
            ),
          ],
        );
      }
    }

    final overrideStatus = statusOverrides['GQL ${op.name}'];
    if (overrideStatus != null) {
      // The override must always take effect: when the operation declares no
      // example errors, synthesize a generic one instead of ignoring it.
      final errors = op.errors.isNotEmpty
          ? op.errors
          : <GraphQLErrorExample>[
              GraphQLErrorExample(
                message: 'Mocked error for ${op.name} '
                    '(statusOverrides: $overrideStatus)',
                extensions: const {'code': 'MOCKED_ERROR'},
              ),
            ];
      return _gqlResponse(overrideStatus, errors: errors);
    }
    return _gqlResponse(200, data: op.responseExample);
  }

  GraphQLOperation? _matchGraphqlOperation(
    GraphQLSection section,
    String? operationName,
    String? document,
  ) {
    GraphQLOperation? named(String? name) {
      if (name == null) return null;
      for (final op in section.operations) {
        if (op.name == name) return op;
      }
      return null;
    }

    final byName = named(operationName) ?? named(_extractOpName(document));
    if (byName != null) return byName;
    if (document != null) {
      // Anonymous or unknown operation: fall back to a declared name that
      // merely appears in the document.
      for (final op in section.operations) {
        if (document.contains(op.name)) return op;
      }
    }
    if (section.operations.length == 1) return section.operations.first;
    return null;
  }

  /// Matches the operation name in a GraphQL document.
  static final RegExp _opNamePattern =
      RegExp(r'(?:query|mutation|subscription)\s+([A-Za-z_][A-Za-z0-9_]*)');

  String? _extractOpName(String? document) {
    if (document == null) return null;
    return _opNamePattern.firstMatch(document)?.group(1);
  }

  AdapterResponse _gqlResponse(
    int statusCode, {
    Object? data,
    List<GraphQLErrorExample> errors = const [],
  }) =>
      jsonResponse(statusCode, {
        'data': data,
        if (errors.isNotEmpty) 'errors': errors.map((e) => e.toJson()).toList(),
      });

  AdapterResponse _gqlError(int statusCode, String message) => _gqlResponse(
        statusCode,
        errors: [GraphQLErrorExample(message: message)],
      );

  @override
  void close() {}
}
