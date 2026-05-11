import 'dart:convert';
import 'api_spec.dart';
import 'graphql_spec.dart';

/// Generates a human-readable Markdown API reference from an [ApiSpec].
class MarkdownDocGenerator {
  MarkdownDocGenerator(this.spec);

  final ApiSpec spec;

  String generate() {
    final buf = StringBuffer();
    buf.writeln('# ${spec.title} — API Reference');
    buf.writeln();
    buf.writeln('Version: `${spec.version}`  ');
    buf.writeln('Base URL: `${spec.baseUrl}`');
    if (spec.description != null) {
      buf.writeln();
      buf.writeln(spec.description);
    }
    buf.writeln();

    final byTag = <String, List<EndpointSpec>>{};
    for (final ep in spec.endpoints) {
      byTag.putIfAbsent(ep.tag ?? 'General', () => []).add(ep);
    }

    buf.writeln('## Table of contents');
    byTag.forEach((tag, eps) {
      buf.writeln('- [$tag](#${_anchor(tag)})');
      for (final ep in eps) {
        buf.writeln(
          '  - [${ep.method} ${ep.path}](#${_anchor('${ep.method} ${ep.path}')})',
        );
      }
    });
    buf.writeln();

    byTag.forEach((tag, eps) {
      buf.writeln('## $tag');
      buf.writeln();
      for (final ep in eps) {
        _writeEndpoint(buf, ep);
      }
    });

    final gql = spec.graphqlSection;
    if (gql != null && gql.operations.isNotEmpty) {
      _writeGraphqlSection(buf, gql);
    }

    return buf.toString();
  }

  void _writeGraphqlSection(StringBuffer buf, GraphQLSection section) {
    buf.writeln('## GraphQL');
    buf.writeln();
    buf.writeln('Endpoint: `POST ${section.endpoint}`');
    if (section.description != null) {
      buf.writeln();
      buf.writeln(section.description);
    }
    buf.writeln();
    for (final op in section.operations) {
      buf.writeln('### `${op.kind.name}` ${op.name}');
      if (op.description != null) {
        buf.writeln();
        buf.writeln(op.description);
      }
      buf.writeln();
      buf.writeln('Auth: ${op.auth ? 'required' : 'public'}');
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
        buf.writeln('| Name | Type | Required |');
        buf.writeln('| --- | --- | --- |');
        op.variables.forEach((k, s) {
          buf.writeln('| `$k` | `${s.type}` | ${s.required ? 'yes' : 'no'} |');
        });
        buf.writeln();
      }
      if (op.responseExample != null) {
        buf.writeln('**Example `data`**');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(_pretty(op.responseExample));
        buf.writeln('```');
        buf.writeln();
      }
      buf.writeln('---');
      buf.writeln();
    }
  }

  void _writeEndpoint(StringBuffer buf, EndpointSpec ep) {
    buf.writeln('### ${ep.method} ${ep.path}');
    if (ep.summary != null) {
      buf.writeln();
      buf.writeln('_${ep.summary}_');
    }
    if (ep.description != null) {
      buf.writeln();
      buf.writeln(ep.description);
    }
    buf.writeln();
    buf.writeln('Auth: ${ep.auth ? 'required' : 'public'}');
    buf.writeln();

    if (ep.pathParams.isNotEmpty) {
      buf.writeln('**Path parameters**');
      buf.writeln();
      buf.writeln('| Name | Type | Required | Description |');
      buf.writeln('| --- | --- | --- | --- |');
      ep.pathParams.forEach((k, s) {
        buf.writeln(
          '| `$k` | `${s.type}` | ${s.required ? 'yes' : 'no'} | ${s.description ?? ''} |',
        );
      });
      buf.writeln();
    }
    if (ep.queryParams.isNotEmpty) {
      buf.writeln('**Query parameters**');
      buf.writeln();
      buf.writeln('| Name | Type | Required | Description |');
      buf.writeln('| --- | --- | --- | --- |');
      ep.queryParams.forEach((k, s) {
        buf.writeln(
          '| `$k` | `${s.type}` | ${s.required ? 'yes' : 'no'} | ${s.description ?? ''} |',
        );
      });
      buf.writeln();
    }

    if (ep.request != null) {
      buf.writeln('**Request body**');
      buf.writeln();
      if (ep.request!.schema != null) {
        buf.writeln('Schema:');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(_pretty(ep.request!.schema!.toOpenApi()));
        buf.writeln('```');
      }
      if (ep.request!.body != null) {
        buf.writeln();
        buf.writeln('Example:');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(_pretty(ep.request!.body));
        buf.writeln('```');
      }
      buf.writeln();
    }

    if (ep.responses.isNotEmpty) {
      buf.writeln('**Responses**');
      buf.writeln();
      for (final r in ep.responses) {
        buf.writeln('- `${r.statusCode}` ${r.description ?? ''}');
        if (r.body != null) {
          buf.writeln();
          buf.writeln('  ```json');
          for (final line in _pretty(r.body).split('\n')) {
            buf.writeln('  $line');
          }
          buf.writeln('  ```');
        }
      }
      buf.writeln();
    }

    final basePath = Uri.parse(spec.baseUrl).toString();
    buf.writeln('**cURL**');
    buf.writeln();
    buf.writeln('```bash');
    buf.writeln(_curl(ep, basePath));
    buf.writeln('```');
    buf.writeln();
    buf.writeln('---');
    buf.writeln();
  }

  String _curl(EndpointSpec ep, String base) {
    final path = ep.path.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (m) {
      final schema = ep.pathParams[m.group(1)];
      return '${schema?.example ?? ':${m.group(1)}'}';
    });
    final buf = StringBuffer('curl -X ${ep.method}');
    if (ep.auth) buf.write(" -H 'Authorization: Bearer <token>'");
    if (ep.request?.body != null) {
      buf.write(" -H 'Content-Type: application/json'");
      buf.write(" --data '${jsonEncode(ep.request!.body)}'");
    }
    buf.write(" '$base$path'");
    return buf.toString();
  }

  String _pretty(Object? v) => const JsonEncoder.withIndent('  ').convert(v);

  String _anchor(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 -]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '-');
}
