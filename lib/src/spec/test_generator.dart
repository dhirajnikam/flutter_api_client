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
  ///
  /// The output is `dart format`-clean on the first pass: test blocks are
  /// assembled and joined with single blank-line separators rather than
  /// streamed, so no trailing blank lines are left before a closing brace.
  String generate() {
    final header = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
      ..writeln('// Regenerate: dart run flutter_api_client:gen --only tests')
      ..writeln()
      ..writeln("import 'package:flutter_api_client/flutter_api_client.dart';")
      ..writeln("import 'package:flutter_test/flutter_test.dart';");
    if (specImport != null) {
      header.writeln("import '$specImport';");
    }

    final byTag = <String, List<EndpointSpec>>{};
    for (final ep in spec.endpoints) {
      byTag.putIfAbsent(ep.tag ?? 'General', () => []).add(ep);
    }

    final groups = <String>[];
    byTag.forEach((tag, endpoints) {
      final blocks = [
        for (final ep in endpoints) ..._endpointTestBlocks(ep),
      ];
      final body = blocks.join('\n\n');
      groups.add("  group('$tag', () {\n$body\n  });");
    });

    return '$header\nvoid main() {\n${groups.join('\n\n')}\n}\n';
  }

  // Verbs the generated client (ApiClient) actually exposes. A spec endpoint
  // using anything else (e.g. HEAD) would emit `client.head(...)`, which does
  // not compile — so skip it with a visible note instead.
  static const _supportedMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};

  /// Builds the individual `test(...)` blocks for one endpoint. Each returned
  /// string is a self-contained block with no leading or trailing blank line;
  /// the caller joins them with blank-line separators.
  List<String> _endpointTestBlocks(EndpointSpec ep) {
    if (!_supportedMethods.contains(ep.method.toUpperCase())) {
      return [
        '    // ${ep.method} ${ep.path} — skipped: ApiClient has no '
            '${ep.method.toLowerCase()}() method.',
      ];
    }
    final baseUrl = spec.baseUrl;
    final methodKey = '${ep.method} ${ep.path}';
    final concretePath = ep.path
        .replaceAllMapped(_placeholder, (_) => '1')
        .replaceFirst(_leadingSlash, '');
    final method = ep.method.toLowerCase();
    final blocks = <String>[];

    // Happy path
    blocks.add([
      "    test('${ep.method} ${ep.path} — happy path', () async {",
      _clientSetup(baseUrl, null),
      _callLine(ep, concretePath),
      '      expect(res.isSuccess, true);',
      '    });',
    ].join('\n'));

    // Schema validation failure
    if (ep.request?.schema != null) {
      blocks.add([
        "    test('${ep.method} ${ep.path} — schema validation rejects bad body', () async {",
        _clientSetup(baseUrl, null),
        "      final res = await client.$method<dynamic>('$concretePath', <String, dynamic>{});",
        '      expect(res.statusCode, 422);',
        '    });',
      ].join('\n'));
    }

    // Auth required
    if (ep.auth) {
      blocks.add([
        "    test('${ep.method} ${ep.path} — auth required returns 401', () async {",
        _clientSetup(baseUrl, "'$methodKey': 401"),
        _callLine(ep, concretePath),
        '      expect(res.statusCode, 401);',
        '    });',
      ].join('\n'));
    }

    // Explicit error responses
    for (final r in ep.responses.where((r) => !r.isSuccess)) {
      blocks.add([
        "    test('${ep.method} ${ep.path} — returns ${r.statusCode}', () async {",
        _clientSetup(baseUrl, "'$methodKey': ${r.statusCode}"),
        _callLine(ep, concretePath),
        '      expect(res.statusCode, ${r.statusCode});',
        '    });',
      ].join('\n'));
    }

    return blocks;
  }

  String _clientSetup(String baseUrl, String? statusOverride) {
    // Emitted in the fully-expanded form Dart's formatter produces for a nested
    // constructor call, so the generated file is `dart format`-clean up front.
    final adapter = statusOverride == null
        ? 'SpecMockAdapter($specSymbol)'
        : 'SpecMockAdapter(\n'
            '            $specSymbol,\n'
            '            statusOverrides: const {$statusOverride},\n'
            '          )';
    return '      final client = ApiClient(\n'
        '        ApiClientConfig.test(\n'
        "          baseUrl: '$baseUrl',\n"
        '          adapter: $adapter,\n'
        '        ),\n'
        '      );';
  }

  String _callLine(EndpointSpec ep, String path) {
    final method = ep.method.toLowerCase();
    if (method == 'get' || method == 'delete') {
      return "      final res = await client.$method<dynamic>('$path');";
    }
    final body = ep.request?.body;
    final literal = body != null ? _dartLiteral(body) : '<String, dynamic>{}';
    return "      final res = await client.$method<dynamic>('$path', $literal);";
  }

  String _dartLiteral(Object? value) {
    if (value == null) return 'null';
    if (value is String) return "'${_escapeDartString(value)}'";
    if (value is num || value is bool) return '$value';
    if (value is Map) {
      final entries = value.entries
          .map((e) => '${_dartLiteral('${e.key}')}: ${_dartLiteral(e.value)}')
          .join(', ');
      return '{$entries}';
    }
    if (value is List) {
      return '[${value.map(_dartLiteral).join(', ')}]';
    }
    return "'${_escapeDartString('$value')}'";
  }

  /// Escapes [s] for a single-quoted Dart string literal. Without this, an
  /// example body containing `'`, `$`, `\`, or a newline produces generated
  /// test code that does not compile.
  String _escapeDartString(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll(r'$', r'\$')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
}
