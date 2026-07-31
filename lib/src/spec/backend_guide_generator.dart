import 'dart:convert';

import 'api_spec.dart';
import 'graphql_spec.dart';
import 'schema.dart';

/// Generates a backend-implementation guide in Markdown. Designed to be
/// handed to a backend engineer so they can build the API surface the
/// client expects.
class BackendGuideGenerator {
  /// Creates a generator for [spec], optionally emitting [framework]-specific
  /// handler snippets.
  BackendGuideGenerator(this.spec, {this.framework = BackendFramework.none});

  /// The spec this guide is generated from.
  final ApiSpec spec;

  /// Target backend framework for the emitted code snippets.
  final BackendFramework framework;

  // Fixed patterns reused across every endpoint — compiled once.
  static final RegExp _placeholder = RegExp(r'\{([^}]+)\}');
  static final RegExp _braces = RegExp(r'\{|\}');

  /// Renders the full backend implementation guide in Markdown.
  String generate() {
    final buf = StringBuffer();
    buf.writeln('# ${spec.title} — Backend Implementation Guide');
    buf.writeln();
    buf.writeln('Version: `${spec.version}`  ');
    buf.writeln('Base URL: `${spec.baseUrl}`');
    buf.writeln();
    buf.writeln(
      'This guide is auto-generated from the client-side API spec. '
      'Implementing every endpoint as described will make the official '
      'client work with no extra work.',
    );
    buf.writeln();

    _writeArchitecture(buf);
    _writeRouteTable(buf);
    _writeAuth(buf);
    _writeErrorEnvelope(buf);
    _writeEndpoints(buf);
    final gql = spec.graphqlSection;
    if (gql != null && gql.operations.isNotEmpty) {
      _writeGraphql(buf, gql);
    }
    _writeChecklist(buf);

    return buf.toString();
  }

  void _writeArchitecture(StringBuffer buf) {
    buf.writeln('## Suggested architecture');
    buf.writeln();
    buf.writeln('```');
    buf.writeln('  ┌─────────────┐    HTTPS     ┌───────────────┐');
    buf.writeln('  │ Mobile/Web  │ ───────────► │   API Gateway │');
    buf.writeln('  │   client    │              └──────┬────────┘');
    buf.writeln('  └─────────────┘                     │');
    buf.writeln('                                      ▼');
    buf.writeln('                            ┌──────────────────┐');
    buf.writeln('                            │  Auth middleware │');
    buf.writeln('                            └──────┬───────────┘');
    buf.writeln('                                   ▼');
    buf.writeln('                            ┌──────────────────┐');
    buf.writeln('                            │  Route handlers  │');
    buf.writeln('                            └──────┬───────────┘');
    buf.writeln('                                   ▼');
    buf.writeln('                            ┌──────────────────┐');
    buf.writeln('                            │ Domain services  │');
    buf.writeln('                            └──────┬───────────┘');
    buf.writeln('                                   ▼');
    buf.writeln('                            ┌──────────────────┐');
    buf.writeln('                            │      Database    │');
    buf.writeln('                            └──────────────────┘');
    buf.writeln('```');
    buf.writeln();
    buf.writeln('Layering:');
    buf.writeln('1. **Transport / Routing** — HTTP framework of your choice.');
    buf.writeln(
      '2. **Validation** — reject malformed inputs early with `422`.',
    );
    buf.writeln('3. **Auth** — JWT/Session, reject missing token with `401`.');
    buf.writeln('4. **Business logic** — pure functions where possible.');
    buf.writeln(
      '5. **Persistence** — repositories return domain models, not rows.',
    );
    buf.writeln();
  }

  void _writeRouteTable(StringBuffer buf) {
    buf.writeln('## Route table');
    buf.writeln();
    buf.writeln('| Method | Path | Auth | Suggested handler | Tag |');
    buf.writeln('| --- | --- | --- | --- | --- |');
    for (final ep in spec.endpoints) {
      buf.writeln(
        '| `${ep.method}` | `${ep.path}` | ${ep.auth ? 'required' : 'public'} | `${_handlerName(ep)}` | ${ep.tag ?? '-'} |',
      );
    }
    buf.writeln();
  }

  void _writeAuth(StringBuffer buf) {
    buf.writeln('## Authentication');
    buf.writeln();
    buf.writeln(
      'Bearer tokens carried in the `Authorization` header. Reject missing or invalid tokens with `401`.',
    );
    buf.writeln();
    buf.writeln('```');
    buf.writeln('Authorization: Bearer <jwt>');
    buf.writeln('```');
    buf.writeln();
    buf.writeln(
      'When a token expires, return `401` with `{"message": "token expired"}` so the client can trigger refresh.',
    );
    buf.writeln();
  }

  void _writeErrorEnvelope(StringBuffer buf) {
    buf.writeln('## Error envelope');
    buf.writeln();
    buf.writeln('All non-2xx responses must use this shape:');
    buf.writeln();
    buf.writeln('```json');
    buf.writeln('{');
    buf.writeln('  "message": "Human readable message",');
    buf.writeln('  "errors": {');
    buf.writeln('    "field": ["one or more reasons"]');
    buf.writeln('  }');
    buf.writeln('}');
    buf.writeln('```');
    buf.writeln();
    buf.writeln('Status code matrix:');
    buf.writeln();
    buf.writeln('| Code | Meaning |');
    buf.writeln('| --- | --- |');
    buf.writeln('| 200 | OK — read or generic success |');
    buf.writeln('| 201 | Created — resource was created |');
    buf.writeln('| 204 | No Content — write succeeded, nothing to return |');
    buf.writeln('| 400 | Bad Request — malformed input |');
    buf.writeln('| 401 | Unauthorized — missing/expired token |');
    buf.writeln('| 403 | Forbidden — authenticated but not allowed |');
    buf.writeln('| 404 | Not Found — resource missing |');
    buf.writeln('| 409 | Conflict — version / duplicate |');
    buf.writeln('| 422 | Unprocessable Entity — validation failed |');
    buf.writeln('| 429 | Too Many Requests — rate limited |');
    buf.writeln('| 500 | Internal Server Error |');
    buf.writeln();
  }

  void _writeEndpoints(StringBuffer buf) {
    buf.writeln('## Endpoint implementation details');
    buf.writeln();
    for (final ep in spec.endpoints) {
      buf.writeln('### ${ep.method} ${ep.path}');
      if (ep.summary != null) {
        buf.writeln();
        buf.writeln('_${ep.summary}_');
      }
      buf.writeln();
      buf.writeln('**Validation rules**');
      buf.writeln();
      final rules = _rulesFor(ep);
      if (rules.isEmpty) {
        buf.writeln('- None');
      } else {
        for (final r in rules) {
          buf.writeln('- $r');
        }
      }
      buf.writeln();

      buf.writeln('**Status codes returned**');
      buf.writeln();
      if (ep.responses.isEmpty) {
        buf.writeln('- `204` No Content');
      } else {
        for (final r in ep.responses) {
          buf.writeln(
            '- `${r.statusCode}` ${r.description ?? _phrase(r.statusCode)}',
          );
        }
      }
      buf.writeln();

      if (ep.request?.body != null) {
        buf.writeln('**Example request body**');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(_pretty(ep.request!.body));
        buf.writeln('```');
        buf.writeln();
      }
      if (ep.firstSuccess?.body != null) {
        buf.writeln('**Example success response**');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(_pretty(ep.firstSuccess!.body));
        buf.writeln('```');
        buf.writeln();
      }

      buf.writeln('**Handler skeleton (pseudocode)**');
      buf.writeln();
      buf.writeln('```');
      buf.writeln('function ${_handlerName(ep)}(req):');
      if (ep.auth) buf.writeln('  user = require_auth(req)');
      if (ep.pathParams.isNotEmpty) {
        for (final k in ep.pathParams.keys) {
          buf.writeln('  $k = req.path.$k');
        }
      }
      if (ep.queryParams.isNotEmpty) {
        for (final k in ep.queryParams.keys) {
          buf.writeln('  $k = req.query.$k');
        }
      }
      if (ep.request != null) {
        buf.writeln('  body = validate(req.body, RequestSchema)');
      }
      buf.writeln('  result = service.${_serviceName(ep)}(...)');
      buf.writeln('  return ${ep.firstSuccess?.statusCode ?? 200}, result');
      buf.writeln('```');
      buf.writeln();

      final snippet = _frameworkSnippet(ep);
      if (snippet != null) {
        buf.writeln('**${framework.name} snippet**');
        buf.writeln();
        buf.writeln('```${framework.lang}');
        buf.writeln(snippet);
        buf.writeln('```');
        buf.writeln();
      }
      buf.writeln('---');
      buf.writeln();
    }
  }

  void _writeChecklist(StringBuffer buf) {
    buf.writeln('## Acceptance checklist');
    buf.writeln();
    for (final ep in spec.endpoints) {
      buf.writeln('### ${ep.method} ${ep.path}');
      buf.writeln('- [ ] Route registered');
      if (ep.auth) buf.writeln('- [ ] Auth middleware applied');
      if (ep.request != null) buf.writeln('- [ ] Request body validated');
      buf.writeln('- [ ] Success path returns expected status & shape');
      buf.writeln('- [ ] Errors use the standard envelope');
      buf.writeln('- [ ] Integration test against the spec mock matches');
      buf.writeln();
    }
    final gql = spec.graphqlSection;
    if (gql != null) {
      for (final op in gql.operations) {
        buf.writeln('### GraphQL ${op.kind.name} ${op.name}');
        buf.writeln('- [ ] Resolver wired to schema');
        if (op.auth) buf.writeln('- [ ] Auth check inside resolver');
        if (op.variables.isNotEmpty) {
          buf.writeln('- [ ] Variables validated');
        }
        buf.writeln('- [ ] Returns expected `data` shape');
        buf.writeln(
          '- [ ] Errors surfaced via `errors[]` with `extensions.code`',
        );
        buf.writeln();
      }
    }
  }

  void _writeGraphql(StringBuffer buf, GraphQLSection section) {
    buf.writeln('## GraphQL');
    buf.writeln();
    if (section.description != null) {
      buf.writeln(section.description);
      buf.writeln();
    }
    buf.writeln('GraphQL gateway path: `${section.endpoint}` (HTTP `POST`).');
    buf.writeln();
    buf.writeln('Standard envelope:');
    buf.writeln();
    buf.writeln('```json');
    buf.writeln('{');
    buf.writeln('  "data": { ... },');
    buf.writeln(
      '  "errors": [{ "message": "...", "path": [...], "extensions": { "code": "..." } }],',
    );
    buf.writeln('  "extensions": { ... }');
    buf.writeln('}');
    buf.writeln('```');
    buf.writeln();

    buf.writeln('### Operation table');
    buf.writeln();
    buf.writeln('| Kind | Name | Auth | Resolver |');
    buf.writeln('| --- | --- | --- | --- |');
    for (final op in section.operations) {
      buf.writeln(
        '| `${op.kind.name}` | `${op.name}` | ${op.auth ? 'required' : 'public'} | `${_resolverName(op)}` |',
      );
    }
    buf.writeln();

    buf.writeln('### Suggested SDL');
    buf.writeln();
    buf.writeln('```graphql');
    buf.writeln(_buildSdl(section));
    buf.writeln('```');
    buf.writeln();

    for (final op in section.operations) {
      _writeGraphqlOperation(buf, section, op);
    }
  }

  void _writeGraphqlOperation(
    StringBuffer buf,
    GraphQLSection section,
    GraphQLOperation op,
  ) {
    buf.writeln('### `${op.kind.name}` ${op.name}');
    if (op.description != null) {
      buf.writeln();
      buf.writeln(op.description);
    }
    buf.writeln();
    buf.writeln('**Document**');
    buf.writeln();
    buf.writeln('```graphql');
    buf.writeln(op.document.trim());
    buf.writeln('```');
    buf.writeln();
    if (op.variables.isNotEmpty) {
      buf.writeln('**Variables**');
      buf.writeln();
      buf.writeln('| Name | Type | Required | Notes |');
      buf.writeln('| --- | --- | --- | --- |');
      op.variables.forEach((k, s) {
        buf.writeln(
          '| `$k` | `${s.type}` | ${s.required ? 'yes' : 'no'} | ${_schemaSummary(s)} |',
        );
      });
      buf.writeln();
    }
    if (op.responseExample != null) {
      buf.writeln('**Example success response (`data`)**');
      buf.writeln();
      buf.writeln('```json');
      buf.writeln(_pretty(op.responseExample));
      buf.writeln('```');
      buf.writeln();
    }
    if (op.errors.isNotEmpty) {
      buf.writeln('**Example errors**');
      buf.writeln();
      for (final e in op.errors) {
        buf.writeln(
          '- `${e.message}`'
          '${e.extensions == null ? '' : ' — code: `${e.extensions!['code'] ?? '-'}`'}',
        );
      }
      buf.writeln();
    }

    buf.writeln('**Resolver skeleton (pseudocode)**');
    buf.writeln();
    buf.writeln('```');
    buf.writeln('function ${_resolverName(op)}(parent, args, ctx):');
    if (op.auth) buf.writeln('  user = require_auth(ctx)');
    if (op.variables.isNotEmpty) {
      for (final k in op.variables.keys) {
        buf.writeln('  $k = args.$k');
      }
    }
    buf.writeln('  validate(args, VariableSchema)');
    buf.writeln('  return service.${_resolverName(op)}(...)');
    buf.writeln('```');
    buf.writeln();

    final snippet = _graphqlFrameworkSnippet(op);
    if (snippet != null) {
      buf.writeln('**${framework.name} snippet**');
      buf.writeln();
      buf.writeln('```${framework.lang}');
      buf.writeln(snippet);
      buf.writeln('```');
      buf.writeln();
    }
    buf.writeln('---');
    buf.writeln();
  }

  String _buildSdl(GraphQLSection section) {
    final buf = StringBuffer();
    final queries =
        section.operations.where((o) => o.isQuery).toList(growable: false);
    final mutations =
        section.operations.where((o) => o.isMutation).toList(growable: false);
    final subscriptions = section.operations
        .where((o) => o.isSubscription)
        .toList(growable: false);

    void writeBlock(String name, List<GraphQLOperation> ops) {
      if (ops.isEmpty) return;
      buf.writeln('type $name {');
      for (final op in ops) {
        final args = op.variables.entries
            .map((e) => '${e.key}: ${_gqlType(e.value)}')
            .join(', ');
        final ret = _gqlReturnType(op);
        buf.writeln(
          '  ${_lowerFirst(op.name)}${args.isEmpty ? '' : '($args)'}: $ret',
        );
      }
      buf.writeln('}');
      buf.writeln();
    }

    writeBlock('Query', queries);
    writeBlock('Mutation', mutations);
    writeBlock('Subscription', subscriptions);
    return buf.toString().trimRight();
  }

  String _gqlType(Schema s) {
    final base = switch (s.type) {
      'string' => 'String',
      'integer' => 'Int',
      'number' => 'Float',
      'boolean' => 'Boolean',
      'array' => '[${s.items == null ? 'JSON' : _gqlType(s.items!)}]',
      _ => 'JSON',
    };
    return s.required ? '$base!' : base;
  }

  String _gqlReturnType(GraphQLOperation op) {
    final ex = op.responseExample;
    if (ex is Map && ex.isNotEmpty) {
      final first = ex.values.first;
      if (first is List) return '[${op.name}Payload]';
      return '${op.name}Payload';
    }
    return 'JSON';
  }

  String _lowerFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  String _resolverName(GraphQLOperation op) => _lowerFirst(op.name);

  String? _graphqlFrameworkSnippet(GraphQLOperation op) {
    final args = op.variables.keys.map((k) => k).join(', ');
    switch (framework) {
      case BackendFramework.express:
        return 'const resolvers = {\n'
            '  ${op.isMutation ? 'Mutation' : op.isSubscription ? 'Subscription' : 'Query'}: {\n'
            '    ${_resolverName(op)}: async (_, { $args }, ctx) => {\n'
            '      ${op.auth ? 'await requireAuth(ctx);\n      ' : ''}// TODO: implement\n'
            '      return {};\n'
            '    },\n'
            '  },\n'
            '};';
      case BackendFramework.fastapi:
        return '@strawberry.${op.isMutation ? 'mutation' : 'field'}\n'
            'async def ${_resolverName(op)}(self${args.isEmpty ? '' : ', $args'}) -> dict:\n'
            '    # TODO: implement\n'
            '    return {}';
      case BackendFramework.gin:
        return '// gqlgen resolver\n'
            'func (r *${op.isMutation ? 'mutationResolver' : 'queryResolver'}) ${_capitalize(op.name)}(ctx context.Context${args.isEmpty ? '' : ', $args interface{}'}) (interface{}, error) {\n'
            '    // TODO: implement\n'
            '    return nil, nil\n'
            '}';
      case BackendFramework.none:
        return null;
    }
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  List<String> _rulesFor(EndpointSpec ep) {
    final out = <String>[];
    ep.pathParams.forEach((k, s) {
      out.add('`$k` (path): ${_schemaSummary(s)}');
    });
    ep.queryParams.forEach((k, s) {
      out.add('`$k` (query): ${_schemaSummary(s)}');
    });
    final reqSchema = ep.request?.schema;
    if (reqSchema?.properties != null) {
      reqSchema!.properties!.forEach((k, s) {
        out.add('body.`$k`: ${_schemaSummary(s)}');
      });
    }
    return out;
  }

  String _schemaSummary(Schema s) {
    final parts = <String>['type=${s.type}'];
    if (s.required) parts.add('required');
    if (s.format != null) parts.add('format=${s.format}');
    if (s.minLength != null) parts.add('minLength=${s.minLength}');
    if (s.maxLength != null) parts.add('maxLength=${s.maxLength}');
    if (s.minimum != null) parts.add('min=${s.minimum}');
    if (s.maximum != null) parts.add('max=${s.maximum}');
    if (s.enumValues != null) parts.add('enum=${s.enumValues}');
    return parts.join(', ');
  }

  String? _frameworkSnippet(EndpointSpec ep) {
    // Path placeholders are framework-specific: Express and Gin use `:param`
    // segments, while FastAPI uses `{param}` templates (the spec's own form).
    final colonRoute = ep.path.replaceAllMapped(
      _placeholder,
      (m) => ':${m.group(1)}',
    );
    switch (framework) {
      case BackendFramework.express:
        return "app.${ep.method.toLowerCase()}('$colonRoute', ${ep.auth ? 'requireAuth, ' : ''}async (req, res) => {\n"
            "  // TODO: validate, then call service\n"
            "  res.status(${ep.firstSuccess?.statusCode ?? 200}).json({});\n"
            "});";
      case BackendFramework.fastapi:
        final params = ep.pathParams.keys.map((k) => '$k: str').join(', ');
        return "@app.${ep.method.toLowerCase()}('${ep.path}')\n"
            "async def ${_serviceName(ep)}($params):\n"
            "    # TODO: validate, call service\n"
            "    return {}";
      case BackendFramework.gin:
        return "r.${ep.method.toUpperCase()}(\"$colonRoute\", func(c *gin.Context) {\n"
            "    // TODO: validate, call service\n"
            "    c.JSON(${ep.firstSuccess?.statusCode ?? 200}, gin.H{})\n"
            "})";
      case BackendFramework.none:
        return null;
    }
  }

  String _handlerName(EndpointSpec ep) {
    final parts = ep.path
        .replaceAll(_braces, '')
        .split('/')
        .where((p) => p.isNotEmpty)
        .toList();
    return '${ep.method.toLowerCase()}_${parts.join('_')}';
  }

  String _serviceName(EndpointSpec ep) => _handlerName(ep);

  String _pretty(Object? v) => const JsonEncoder.withIndent('  ').convert(v);

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
        return '';
    }
  }
}

/// Backend framework that [BackendGuideGenerator] emits code snippets for.
enum BackendFramework {
  /// No framework; emit pseudocode only.
  none('plain', ''),

  /// Node.js Express (JavaScript).
  express('express', 'js'),

  /// Python FastAPI (Strawberry for GraphQL).
  fastapi('fastapi', 'python'),

  /// Go Gin (gqlgen for GraphQL).
  gin('gin', 'go');

  const BackendFramework(this.name, this.lang);

  /// Display name used in section headings.
  final String name;

  /// Markdown code-fence language tag for emitted snippets.
  final String lang;
}
