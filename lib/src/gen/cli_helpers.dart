import 'dart:io';

const _validGenerators = ['openapi', 'reference', 'backend', 'tests'];

/// Parses the `--only` flag into a list of generator names.
/// Returns all generators when [only] is null.
/// Throws [ArgumentError] for unknown names.
List<String> parseOnly(String? only) {
  if (only == null) return List.of(_validGenerators);
  final parts = only.split(',').map((s) => s.trim()).toList();
  for (final p in parts) {
    if (!_validGenerators.contains(p)) {
      throw ArgumentError(
        'Unknown generator "$p". Valid values: ${_validGenerators.join(', ')}',
      );
    }
  }
  return parts;
}

/// Searches [searchRoot] recursively for a `.g.dart` file containing
/// `\$generatedSpec`. Returns the first match path, or null if not found.
String? findGeneratedSpecFile(String searchRoot) {
  final dir = Directory(searchRoot);
  if (!dir.existsSync()) return null;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.g.dart')) {
      try {
        if (entity.readAsStringSync().contains(r'$generatedSpec')) {
          // Normalize to forward slashes so callers get a platform-independent
          // path (Directory.listSync yields native `\` separators on Windows),
          // consistent with packageImportFor / packageImportFromLibPath below.
          return entity.path.replaceAll('\\', '/');
        }
      } catch (_) {}
    }
  }
  return null;
}

String? packageImportFor(String packageRoot, String filePath) {
  final pubspec = File('$packageRoot/pubspec.yaml');
  if (!pubspec.existsSync()) return null;

  final packageName = _packageNameFromPubspec(pubspec.readAsStringSync());
  if (packageName == null) return null;

  final root = packageRoot.replaceAll('\\', '/');
  final file = filePath.replaceAll('\\', '/');
  final rootPrefix = root.endsWith('/') ? root : '$root/';
  if (!file.startsWith(rootPrefix)) return null;

  final relativePath = file.substring(rootPrefix.length);
  if (!relativePath.startsWith('lib/')) return null;
  return packageImportFromLibPath(packageName, relativePath);
}

String packageImportFromLibPath(String packageName, String relativeLibPath) {
  final normalized = relativeLibPath.replaceAll('\\', '/');
  if (!normalized.startsWith('lib/')) {
    throw ArgumentError.value(
      relativeLibPath,
      'relativeLibPath',
      'Expected a path under lib/',
    );
  }
  return 'package:$packageName/${normalized.substring(4)}';
}

String buildApiSpecSmokeTestSource({
  required String importPath,
  required String specSymbol,
}) {
  return '''
// GENERATED CODE - DO NOT MODIFY BY HAND
// Run `dart run build_runner build` to regenerate.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import '$importPath';

void main() {
  test('spec loads without error', () {
    expect($specSymbol, isNotNull);
    expect($specSymbol.endpoints, isNotEmpty);
  });

  group('Endpoint registration', () {
    for (final ep in $specSymbol.endpoints) {
      test('\${ep.method} \${ep.path} is registered', () {
        expect(ep.path, startsWith('/'));
        expect(ep.method, isNotEmpty);
      });
    }
  });
}
''';
}

String? _packageNameFromPubspec(String pubspec) {
  final match =
      RegExp(r'^name:\s*([^\s#]+)', multiLine: true).firstMatch(pubspec);
  return match?.group(1);
}
