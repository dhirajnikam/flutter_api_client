import 'dart:convert';
import 'dart:typed_data';

import '../http/http_adapter.dart';
import 'api_spec.dart';
import 'examples.dart';
import 'graphql_spec.dart';

/// Turns an [ApiSpec] into a fully-working mock adapter.
///
/// Matches by method + path template. Validates the request body against
/// the endpoint's request schema. Returns the first success response by
/// default; pass [statusOverrides] to make endpoints return errors during
/// tests.
class SpecMockAdapter implements HttpAdapter {
  SpecMockAdapter(
    this.spec, {
    this.latency,
    this.statusOverrides = const {},
    this.validateRequests = true,
  });

  final ApiSpec spec;
  final Duration? latency;

  /// `{ 'POST /auth/login': 401 }` forces an error response for that endpoint.
  final Map<String, int> statusOverrides;

  final bool validateRequests;

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

    final EndpointSpec? match = _match(req.method, path);
    if (match == null) {
      return AdapterResponse(
        statusCode: 404,
        headers: const {'content-type': 'application/json'},
        bodyBytes: _encode({
          'message': 'No spec endpoint for ${req.method} $path',
        }),
      );
    }
    if (validateRequests && match.request?.schema != null && req.body != null) {
      final body = _decodeBody(req);
      final errors = match.request!.schema!.validate(body);
      if (errors.isNotEmpty) {
        return AdapterResponse(
          statusCode: 422,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _encode({
            'message': 'Validation failed',
            'errors': errors,
          }),
        );
      }
    }

    final overrideKey = '${match.method} ${match.path}';
    final overrideStatus = statusOverrides[overrideKey];
    if (overrideStatus != null) {
      final picked = match.responses.firstWhere(
        (r) => r.statusCode == overrideStatus,
        orElse: () => match.responses.first,
      );
      return _toResponse(picked);
    }

    final success = match.firstSuccess;
    if (success != null) return _toResponse(success);
    if (match.responses.isNotEmpty) return _toResponse(match.responses.first);
    return AdapterResponse(
      statusCode: 204,
      headers: const {'content-type': 'application/json'},
      bodyBytes: Uint8List(0),
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

  AdapterResponse _toResponse(ResponseExample r) => AdapterResponse(
        statusCode: r.statusCode,
        headers: Map<String, String>.from(r.headers),
        bodyBytes: _encode(r.body),
      );

  Uint8List _encode(Object? body) {
    if (body == null) return Uint8List(0);
    if (body is String) return Uint8List.fromList(utf8.encode(body));
    if (body is List<int>) return Uint8List.fromList(body);
    return Uint8List.fromList(utf8.encode(jsonEncode(body)));
  }

  EndpointSpec? _match(String method, String path) {
    for (final ep in spec.endpoints) {
      if (ep.method != method.toUpperCase()) continue;
      if (ep.pathPattern.hasMatch(path)) return ep;
      // Also allow the spec base path prefix to be absent.
      final stripped = _stripBase(path);
      if (stripped != path && ep.pathPattern.hasMatch(stripped)) return ep;
    }
    return null;
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
        data: null,
        errors: [
          GraphQLErrorExample(
            message:
                'Operation "${operationName ?? _extractOpName(document)}" not found in spec',
            extensions: const {'code': 'OPERATION_NOT_FOUND'},
          ),
        ],
      );
    }

    // Optional variables validation.
    if (validateRequests && op.variables.isNotEmpty) {
      final vars = (body['variables'] as Map?)?.cast<String, Object?>() ?? {};
      final problems = <String>[];
      op.variables.forEach((name, schema) {
        problems.addAll(schema.validate(vars[name], name));
      });
      if (problems.isNotEmpty) {
        return _gqlResponse(
          200,
          data: null,
          errors: [
            GraphQLErrorExample(
              message: 'Variable validation failed: ${problems.join('; ')}',
              extensions: const {'code': 'BAD_USER_INPUT'},
            ),
          ],
        );
      }
    }

    final overrideKey = 'GQL ${op.name}';
    final overrideStatus = statusOverrides[overrideKey];
    if (overrideStatus != null && op.errors.isNotEmpty) {
      return _gqlResponse(overrideStatus, data: null, errors: op.errors);
    }
    return _gqlResponse(200, data: op.responseExample, errors: const []);
  }

  GraphQLOperation? _matchGraphqlOperation(
    GraphQLSection section,
    String? operationName,
    String? document,
  ) {
    if (operationName != null) {
      for (final op in section.operations) {
        if (op.name == operationName) return op;
      }
    }
    if (document != null) {
      final name = _extractOpName(document);
      if (name != null) {
        for (final op in section.operations) {
          if (op.name == name) return op;
        }
      }
      // Fallback: substring match by name in the document.
      for (final op in section.operations) {
        if (document.contains(op.name)) return op;
      }
    }
    if (section.operations.length == 1) return section.operations.first;
    return null;
  }

  String? _extractOpName(String? document) {
    if (document == null) return null;
    final m = RegExp(
      r'(?:query|mutation|subscription)\s+([A-Za-z_][A-Za-z0-9_]*)',
    ).firstMatch(document);
    return m?.group(1);
  }

  AdapterResponse _gqlResponse(
    int statusCode, {
    Object? data,
    List<GraphQLErrorExample> errors = const [],
  }) {
    final body = <String, Object?>{
      'data': data,
      if (errors.isNotEmpty) 'errors': errors.map((e) => e.toJson()).toList(),
    };
    return AdapterResponse(
      statusCode: statusCode,
      headers: const {'content-type': 'application/json'},
      bodyBytes: _encode(body),
    );
  }

  AdapterResponse _gqlError(int statusCode, String message) => _gqlResponse(
        statusCode,
        data: null,
        errors: [GraphQLErrorExample(message: message)],
      );

  @override
  void close() {}
}
