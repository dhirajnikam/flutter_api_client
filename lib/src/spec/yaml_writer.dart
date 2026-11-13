/// Renders a JSON-like [value] (maps, lists, scalars) as block-style YAML.
String encodeYaml(Object? value) => _toYaml(value, 0);

bool _nests(Object? v) =>
    (v is Map && v.isNotEmpty) || (v is List && v.isNotEmpty);

String _toYaml(Object? value, int indent) {
  final pad = '  ' * indent;
  if (value == null) return 'null';
  if (value is num || value is bool) return '$value';
  if (value is String) return _yamlString(value);
  if (value is List) {
    if (value.isEmpty) return '[]';
    final buf = StringBuffer();
    for (final v in value) {
      if (_nests(v)) {
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
      // Keys go through the same quoting as string values: the JSON document
      // uses string keys like '200', which a YAML parser would otherwise
      // load as the integer 200.
      final key = k is String ? _yamlString(k) : _toYaml(k, 0);
      // Non-empty collections nest on the following lines; scalars, nulls and
      // empty collections render inline so YAML stays faithful to the JSON
      // document (e.g. `security: []` and empty example arrays survive).
      if (_nests(v)) {
        buf.writeln('$pad$key:');
        buf.writeln(_toYaml(v, indent + 1));
      } else {
        buf.writeln('$pad$key: ${_toYaml(v, 0)}');
      }
    });
    return buf.toString().trimRight();
  }
  return value.toString();
}

/// Characters that force a YAML scalar to be quoted.
final RegExp _yamlSpecial = RegExp(r'[:#\-?\[\]\{\}&*!|>%@`\n]');

/// Plain YAML scalars that a parser would load as a non-string type. A
/// string-typed JSON value matching one of these must be quoted so it stays
/// a string when the YAML is loaded.
const _yamlTypedScalars = {
  'true', 'false', 'null', 'yes', 'no', 'on', 'off', 'y', 'n', '~', //
};

/// Matches YAML 1.1/1.2 numeric scalar forms (ints incl. hex/octal, floats,
/// infinities and NaN).
final RegExp _yamlNumeric = RegExp(
  r'^([-+]?\d[\d_]*(\.[\d_]*)?([eE][-+]?\d+)?'
  r'|[-+]?\.\d[\d_]*([eE][-+]?\d+)?'
  r'|0[xX][0-9a-fA-F_]+'
  r'|0[oO][0-7_]+'
  r'|[-+]?\.(inf|Inf|INF)'
  r'|\.(nan|NaN|NAN))$',
);

String _yamlString(String s) {
  if (s.isEmpty) return '""';
  final needsQuoting = _yamlSpecial.hasMatch(s) ||
      s.startsWith(' ') ||
      s.endsWith(' ') ||
      s.contains('\\') ||
      s.contains('"') ||
      s.contains("'") ||
      s.codeUnits.any((c) => c < 0x20 || c == 0x7F) ||
      _yamlTypedScalars.contains(s.toLowerCase()) ||
      _yamlNumeric.hasMatch(s);
  return needsQuoting ? _quoteYaml(s) : s;
}

/// Renders [s] as a double-quoted YAML scalar, escaping backslashes and
/// quotes and emitting control characters as proper YAML escapes — without
/// this, a value like a regex `^\d{4}$` or a multi-line description would
/// produce unparseable YAML.
String _quoteYaml(String s) {
  final buf = StringBuffer('"');
  // Escaping per character (not with chained replaceAll) means an emitted
  // backslash is never escaped a second time.
  for (final code in s.codeUnits) {
    switch (code) {
      case 0x5C:
        buf.write(r'\\');
      case 0x22:
        buf.write(r'\"');
      case 0x08:
        buf.write(r'\b');
      case 0x09:
        buf.write(r'\t');
      case 0x0A:
        buf.write(r'\n');
      case 0x0C:
        buf.write(r'\f');
      case 0x0D:
        buf.write(r'\r');
      default:
        if (code < 0x20 || code == 0x7F) {
          buf.write(
              '\\x${code.toRadixString(16).padLeft(2, '0').toUpperCase()}');
        } else {
          buf.writeCharCode(code);
        }
    }
  }
  buf.write('"');
  return buf.toString();
}
