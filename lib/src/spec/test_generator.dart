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
      header.writeln("import '${_escapeDartString(specImport!)}';");
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
      groups.add("  group('${_escapeDartString(tag)}', () {\n$body\n  });");
    });

    return '$header\nvoid main() {\n${groups.join('\n\n')}\n}\n';
  }

  // Verbs the generated client (ApiClient) actually exposes. A spec endpoint
  // using anything else (e.g. HEAD) would emit `client.head(...)`, which does
  // not compile — so skip it with a visible note instead.
  static const _supportedMethods = {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'QUERY',
  };

  // Verbs whose ApiClient method takes a request body as the second
  // positional argument. GET and DELETE take only the path.
  static const _bodyMethods = {'POST', 'PUT', 'PATCH', 'QUERY'};

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
    final methodKey = _escapeDartString('${ep.method} ${ep.path}');
    final title = _escapeDartString('${ep.method} ${ep.path}');
    final concretePath = ep.path
        .replaceAllMapped(_placeholder, (_) => '1')
        .replaceFirst(_leadingSlash, '');
    final blocks = <String>[];

    // Happy path
    blocks.add([
      "    test('$title — happy path', () async {",
      _clientSetup(baseUrl, null),
      _callLine(ep, concretePath),
      '      expect(res.isSuccess, true);',
      '    });',
    ].join('\n'));

    // Schema validation failure. Only meaningful when the verb carries a body
    // and the schema actually rejects an empty object (i.e. it has at least
    // one required member) — otherwise the mock would return the success
    // status and the hard-coded 422 assertion would fail.
    final schema = ep.request?.schema;
    final hasRequiredMember =
        schema?.properties?.values.any((s) => s.required) ?? false;
    if (schema != null &&
        hasRequiredMember &&
        _bodyMethods.contains(ep.method.toUpperCase())) {
      blocks.add([
        "    test('$title — schema validation rejects bad body', () async {",
        _clientSetup(baseUrl, null),
        _callLine(ep, concretePath, bodyLiteral: '<String, dynamic>{}'),
        '      expect(res.statusCode, 422);',
        '    });',
      ].join('\n'));
    }

    // Auth required
    if (ep.auth) {
      blocks.add([
        "    test('$title — auth required returns 401', () async {",
        _clientSetup(baseUrl, "'$methodKey': 401"),
        _callLine(ep, concretePath),
        '      expect(res.statusCode, 401);',
        '    });',
      ].join('\n'));
    }

    // Explicit error responses
    for (final r in ep.responses.where((r) => !r.isSuccess)) {
      blocks.add([
        "    test('$title — returns ${r.statusCode}', () async {",
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
        "          baseUrl: '${_escapeDartString(baseUrl)}',\n"
        '          adapter: $adapter,\n'
        '        ),\n'
        '      );';
  }

  String _callLine(EndpointSpec ep, String path, {String? bodyLiteral}) {
    final method = ep.method.toLowerCase();
    final escapedPath = _escapeDartString(path);
    if (!_bodyMethods.contains(ep.method.toUpperCase())) {
      return "      final res = await client.$method<dynamic>('$escapedPath');";
    }
    final body = ep.request?.body;
    final literal = bodyLiteral ??
        (body != null ? _dartLiteral(body) : '<String, dynamic>{}');
    return "      final res = await client.$method<dynamic>('$escapedPath', $literal);";
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
