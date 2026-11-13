import 'api_spec.dart';
import 'spec_text.dart';
import 'yaml_writer.dart';

/// Emits an OpenAPI 3.1 document (JSON or YAML) derived from an [ApiSpec].
class OpenApiGenerator {
  /// Creates a generator for [spec].
  OpenApiGenerator(this.spec);

  /// The spec this generator derives its document from.
  final ApiSpec spec;

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
        {'url': spec.baseUrl},
        for (final s in spec.servers)
          if (s != spec.baseUrl) {'url': s},
      ],
      'paths': paths,
    };
  }

  Map<String, Object?> _operation(EndpointSpec ep) {
    final params = <Map<String, Object?>>[
      for (final e in ep.pathParams.entries)
        {
          'name': e.key,
          'in': 'path',
          'required': true,
          'schema': e.value.toOpenApi(),
        },
      for (final e in ep.queryParams.entries)
        {
          'name': e.key,
          'in': 'query',
          'required': e.value.required,
          'schema': e.value.toOpenApi(),
        },
    ];
    final req = ep.request;
    return {
      if (ep.summary != null) 'summary': ep.summary,
      if (ep.description != null) 'description': ep.description,
      'tags': [if (ep.tag != null) ep.tag],
      if (ep.auth == false) 'security': <Object?>[],
      if (params.isNotEmpty) 'parameters': params,
      if (req != null)
        'requestBody': {
          'required': true,
          'content': {
            'application/json': {
              if (req.schema != null) 'schema': req.schema!.toOpenApi(),
              if (req.body != null) 'example': req.body,
            },
          },
        },
      // OpenAPI 3.1 requires at least one response per operation, hence the
      // implicit 204 for an endpoint that declares none.
      'responses': <String, Map<String, Object?>>{
        for (final r in responsesOrNoContent(ep))
          '${r.statusCode}': {
            'description':
                r.description ?? reasonPhrases[r.statusCode] ?? 'Response',
            if (r.body != null || r.schema != null)
              'content': {
                'application/json': {
                  if (r.schema != null) 'schema': r.schema!.toOpenApi(),
                  if (r.body != null) 'example': r.body,
                },
              },
          },
      },
    };
  }

  /// Renders the OpenAPI document as pretty-printed JSON.
  String toJsonString() => prettyJson(toJson());

  /// Renders the OpenAPI document as YAML.
  String toYaml() => encodeYaml(toJson());
}
