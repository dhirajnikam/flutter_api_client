import 'dart:convert';

import 'api_spec.dart';
import 'examples.dart';
import 'schema.dart';

/// Emits an OpenAPI 3.1 document (JSON or YAML) derived from an [ApiSpec].
class OpenApiGenerator {
  /// Creates a generator for [spec].
  OpenApiGenerator(this.spec);

  /// The spec this generator derives its document from.
  final ApiSpec spec;

  /// Characters that force a YAML scalar to be quoted. Fixed pattern, compiled
  /// once rather than per emitted string.
  static final RegExp _yamlSpecial = RegExp(r'[:#\-?\[\]\{\}&*!|>%@`\n]');

  /// Builds the OpenAPI document as a JSON-encodable map.
  Map<String, Object?> toJson() {
    final paths = <String, Map<String, Object?>>{};
    for (final ep in spec.endpoints) {
      final pathItem = paths.putIfAbsent(ep.path, () => <String, Object?>{});
      pathItem[ep.method.toLowerCase()] = _operation(ep);
    }
    return {
      'openapi': '3.1.0',
      'info': {
        'title': spec.title,
        'version': spec.version,
        if (spec.description != null) 'description': spec.description,
        if (spec.contact != null) 'contact': spec.contact,
        if (spec.license != null) 'license': spec.license,
      },
      'servers': [
        if (spec.servers.isEmpty) {'url': spec.baseUrl},
        for (final s in spec.servers) {'url': s},
      ],
      'paths': paths,
    };
  }

  Map<String, Object?> _operation(EndpointSpec ep) {
    final params = <Map<String, Object?>>[];
    ep.pathParams.forEach((name, Schema schema) {
      params.add({
        'name': name,
        'in': 'path',
        'required': true,
        'schema': schema.toOpenApi(),
      });
    });
    ep.queryParams.forEach((name, Schema schema) {
      params.add({
        'name': name,
        'in': 'query',
        'required': schema.required,
        'schema': schema.toOpenApi(),
      });
    });

    final op = <String, Object?>{
      if (ep.summary != null) 'summary': ep.summary,
      if (ep.description != null) 'description': ep.description,
      'tags': [if (ep.tag != null) ep.tag],
      if (ep.auth == false) 'security': <Object?>[],
      if (params.isNotEmpty) 'parameters': params,
    };

    final req = ep.request;
    if (req != null) {
      op['requestBody'] = {
        'required': true,
        'content': {
          'application/json': {
            if (req.schema != null) 'schema': req.schema!.toOpenApi(),
            if (req.body != null) 'example': req.body,
          },
        },
      };
    }

    final responses = <String, Map<String, Object?>>{};
    for (final ResponseExample r in ep.responses) {
      responses['${r.statusCode}'] = {
        'description': r.description ?? _phrase(r.statusCode),
        if (r.body != null || r.schema != null)
          'content': {
            'application/json': {
              if (r.schema != null) 'schema': r.schema!.toOpenApi(),
              if (r.body != null) 'example': r.body,
            },
          },
      };
    }
    op['responses'] = responses;
    return op;
  }

  String _phrase(int code) {
    switch (code) {
      case 200:
        return 'OK';
      case 201:
        return 'Created';
      case 204:
        return 'No Content';
      case 400:
        return 'Bad Request';
      case 401:
        return 'Unauthorized';
      case 403:
        return 'Forbidden';
      case 404:
        return 'Not Found';
      case 422:
        return 'Unprocessable Entity';
      case 500:
        return 'Internal Server Error';
      default:
        return 'Response';
    }
  }

  /// Renders the OpenAPI document as pretty-printed JSON.
  String toJsonString() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Renders the OpenAPI document as YAML.
  String toYaml() => _toYaml(toJson(), 0);

  String _toYaml(Object? value, int indent) {
    final pad = '  ' * indent;
    if (value == null) return 'null';
    if (value is num || value is bool) return '$value';
    if (value is String) return _yamlString(value);
    if (value is List) {
      if (value.isEmpty) return '[]';
      final buf = StringBuffer();
      for (final v in value) {
        if ((v is Map && v.isNotEmpty) || (v is List && v.isNotEmpty)) {
          // Render the child at zero indent, then hang it off the dash: first
          // line sits after `- `, the rest align two columns past the dash.
          final lines = _toYaml(v, 0).split('\n');
          buf.writeln('$pad- ${lines.first}');
          for (final line in lines.skip(1)) {
            buf.writeln('$pad  $line');
          }
        } else {
          buf.writeln('$pad- ${_toYaml(v, 0)}');
        }
      }
      return buf.toString().trimRight();
    }
    if (value is Map) {
      if (value.isEmpty) return '{}';
      final buf = StringBuffer();
      value.forEach((k, v) {
        // Non-empty collections nest on the following lines; scalars, nulls and
        // empty collections render inline so YAML stays faithful to the JSON
        // document (e.g. `security: []` and empty example arrays survive).
        if ((v is Map && v.isNotEmpty) || (v is List && v.isNotEmpty)) {
          buf.writeln('$pad$k:');
          buf.writeln(_toYaml(v, indent + 1));
        } else {
          buf.writeln('$pad$k: ${_toYaml(v, 0)}');
        }
      });
      return buf.toString().trimRight();
    }
    return value.toString();
  }

  String _yamlString(String s) {
    if (s.isEmpty) return '""';
    final needsQuoting = _yamlSpecial.hasMatch(s) ||
        s.startsWith(' ') ||
        s.endsWith(' ') ||
        const ['true', 'false', 'null', 'yes', 'no'].contains(s.toLowerCase());
    if (needsQuoting) return '"${s.replaceAll('"', r'\"')}"';
    return s;
  }
}
