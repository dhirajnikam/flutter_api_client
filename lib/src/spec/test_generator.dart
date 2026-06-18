import 'api_spec.dart';

/// Generates a complete, runnable `*_test.dart` from an [ApiSpec].
///
/// Call [generate] to get the full Dart source as a string.
/// Mirrors [MarkdownDocGenerator] and [OpenApiGenerator] in shape.
class TestGenerator {
  /// Creates a generator for [spec].
  ///
  /// [specImport] is the import added to the generated test so it can resolve
  /// the spec variable; [specSymbol] is that variable's identifier.
  TestGenerator(
    this.spec, {
    this.specImport,
    this.specSymbol = 'spec',
  });

  /// The spec the generated tests exercise.
  final ApiSpec spec;

  /// Import directive target for the file declaring the spec, if any.
  final String? specImport;

  /// Identifier of the spec variable referenced by the generated tests.
  final String specSymbol;

  // Fixed patterns reused across every endpoint — compiled once.
  static final RegExp _placeholder = RegExp(r'\{[^}]+\}');
  static final RegExp _leadingSlash = RegExp(r'^/');

  /// Renders a complete, runnable `*_test.dart` source as a string.
  String generate() {
    final buf = StringBuffer();
    buf.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buf.writeln('// Regenerate: dart run flutter_api_client:gen --only tests');
    buf.writeln();
    buf.writeln("import 'package:flutter_api_client/flutter_api_client.dart';");
    buf.writeln("import 'package:flutter_test/flutter_test.dart';");
    if (specImport != null) {
      buf.writeln("import '$specImport';");
    }
    buf.writeln();

    final byTag = <String, List<EndpointSpec>>{};
    for (final ep in spec.endpoints) {
      byTag.putIfAbsent(ep.tag ?? 'General', () => []).add(ep);
    }

    buf.writeln('void main() {');
    byTag.forEach((tag, endpoints) {
      buf.writeln("  group('$tag', () {");
      for (final ep in endpoints) {
        _writeEndpointTests(buf, ep);
      }
      buf.writeln('  });');
      buf.writeln();
    });
    buf.writeln('}');
    return buf.toString();
  }

  void _writeEndpointTests(StringBuffer buf, EndpointSpec ep) {
    final baseUrl = spec.baseUrl;
    final methodKey = '${ep.method} ${ep.path}';
    final concretePath = ep.path
        .replaceAllMapped(_placeholder, (_) => '1')
        .replaceFirst(_leadingSlash, '');

    // Happy path
    buf.writeln("    test('${ep.method} ${ep.path} — happy path', () async {");
    buf.writeln(_clientSetup(baseUrl, ''));
    buf.writeln(_callLine(ep, concretePath));
    buf.writeln('      expect(res.isSuccess, true);');
    buf.writeln('    });');
    buf.writeln();

    // Schema validation failure
    if (ep.request?.schema != null) {
      buf.writeln(
          "    test('${ep.method} ${ep.path} — schema validation rejects bad body', () async {");
      buf.writeln(_clientSetup(baseUrl, ''));
      final method = ep.method.toLowerCase();
      buf.writeln(
          "      final res = await client.$method<dynamic>('$concretePath', <String, dynamic>{});");
      buf.writeln('      expect(res.statusCode, 422);');
      buf.writeln('    });');
      buf.writeln();
    }

    // Auth required
    if (ep.auth) {
      buf.writeln(
          "    test('${ep.method} ${ep.path} — auth required returns 401', () async {");
      buf.writeln(_clientSetup(
          baseUrl, ", statusOverrides: const {'$methodKey': 401}"));
      buf.writeln(_callLine(ep, concretePath));
      buf.writeln('      expect(res.statusCode, 401);');
      buf.writeln('    });');
      buf.writeln();
    }

    // Explicit error responses
    for (final r in ep.responses.where((r) => !r.isSuccess)) {
      buf.writeln(
          "    test('${ep.method} ${ep.path} — returns ${r.statusCode}', () async {");
      buf.writeln(_clientSetup(
          baseUrl, ", statusOverrides: const {'$methodKey': ${r.statusCode}}"));
      buf.writeln(_callLine(ep, concretePath));
      buf.writeln('      expect(res.statusCode, ${r.statusCode});');
      buf.writeln('    });');
      buf.writeln();
    }
  }

  String _clientSetup(String baseUrl, String overrides) =>
      '      final client = ApiClient(ApiClientConfig.test(\n'
      "        baseUrl: '$baseUrl',\n"
      '        adapter: SpecMockAdapter($specSymbol$overrides),\n'
      '      ));';

  String _callLine(EndpointSpec ep, String path) {
    final method = ep.method.toLowerCase();
    if (method == 'get' || method == 'delete' || method == 'head') {
      return "      final res = await client.$method<dynamic>('$path');";
    }
    final body = ep.request?.body;
    final literal = body != null ? _dartLiteral(body) : '<String, dynamic>{}';
    return "      final res = await client.$method<dynamic>('$path', $literal);";
  }

  String _dartLiteral(Object? value) {
    if (value == null) return 'null';
    if (value is String) return "'$value'";
    if (value is num || value is bool) return '$value';
    if (value is Map) {
      final entries = value.entries
          .map((e) => "'${e.key}': ${_dartLiteral(e.value)}")
          .join(', ');
      return '{$entries}';
    }
    if (value is List) {
      return '[${value.map(_dartLiteral).join(', ')}]';
    }
    return "'$value'";
  }
}
