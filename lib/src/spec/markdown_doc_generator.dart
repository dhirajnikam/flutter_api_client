import 'dart:convert';

import 'api_spec.dart';
import 'path_placeholder.dart';
import 'graphql_spec.dart';
import 'schema.dart';
import 'spec_text.dart';

/// Generates a human-readable Markdown API reference from an [ApiSpec].
class MarkdownDocGenerator {
  /// Creates a generator for [spec].
  MarkdownDocGenerator(this.spec);

  /// The spec this generator documents.
  final ApiSpec spec;

  static final RegExp _anchorStrip = RegExp(r'[^a-z0-9 -]');
  static final RegExp _anchorSpaces = RegExp(r'\s+');

  late final String _baseUrl = Uri.parse(spec.baseUrl).toString();

  /// Renders the full Markdown API reference.
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

    final byTag = endpointsByTag(spec);

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
        buf.writeln(prettyJson(op.responseExample));
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

    _writeParams(buf, 'Path parameters', ep.pathParams);
    _writeParams(buf, 'Query parameters', ep.queryParams);

    if (ep.request != null) {
      buf.writeln('**Request body**');
      buf.writeln();
      if (ep.request!.schema != null) {
        buf.writeln('Schema:');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(prettyJson(ep.request!.schema!.toOpenApi()));
        buf.writeln('```');
      }
      if (ep.request!.body != null) {
        buf.writeln();
        buf.writeln('Example:');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(prettyJson(ep.request!.body));
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
          for (final line in prettyJson(r.body).split('\n')) {
            buf.writeln('  $line');
          }
          buf.writeln('  ```');
        }
      }
      buf.writeln();
    }

    buf.writeln('**cURL**');
    buf.writeln();
    buf.writeln('```bash');
    buf.writeln(_curl(ep));
    buf.writeln('```');
    buf.writeln();
    buf.writeln('---');
    buf.writeln();
  }

  void _writeParams(
      StringBuffer buf, String title, Map<String, Schema> params) {
    if (params.isEmpty) return;
    buf.writeln('**$title**');
    buf.writeln();
    buf.writeln('| Name | Type | Required | Description |');
    buf.writeln('| --- | --- | --- | --- |');
    params.forEach((k, s) {
      buf.writeln(
        '| `$k` | `${s.type}` | ${s.required ? 'yes' : 'no'} | ${s.description ?? ''} |',
      );
    });
    buf.writeln();
  }

  String _curl(EndpointSpec ep) {
    final path = ep.path.replaceAllMapped(pathPlaceholder, (m) {
      final schema = ep.pathParams[m.group(1)];
      return '${schema?.example ?? ':${m.group(1)}'}';
    });
    final buf = StringBuffer('curl -X ${ep.method}');
    if (ep.auth) buf.write(" -H 'Authorization: Bearer <token>'");
    if (ep.request?.body != null) {
      buf.write(" -H 'Content-Type: application/json'");
      buf.write(" --data '${jsonEncode(ep.request!.body)}'");
    }
    buf.write(" '$_baseUrl$path'");
    return buf.toString();
  }

  String _anchor(String s) => s
      .toLowerCase()
      .replaceAll(_anchorStrip, '')
      .trim()
      .replaceAll(_anchorSpaces, '-');
}
