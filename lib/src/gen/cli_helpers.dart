import 'dart:io';

import 'package_import.dart';

/// Generator names accepted by `--only`.
const validGenerators = ['openapi', 'reference', 'backend', 'tests'];

/// Parses the `--only` flag into a list of generator names.
/// Returns all generators when [only] is null.
/// Throws [ArgumentError] for unknown names.
List<String> parseOnly(String? only) {
  if (only == null) return List.of(validGenerators);
  final parts = only.split(',').map((s) => s.trim()).toList();
  for (final p in parts) {
    if (!validGenerators.contains(p)) {
      throw ArgumentError(
        'Unknown generator "$p". Valid values: ${validGenerators.join(', ')}',
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
        if (entity.readAsStringSync().contains(generatedSpecGetter)) {
          // Directory.listSync yields native `\` separators on Windows;
          // callers rely on forward slashes.
          return entity.path.replaceAll('\\', '/');
        }
      } catch (_) {}
    }
  }
  return null;
}

/// The `package:` URI for [filePath] under [packageRoot]'s `lib/`, or null if
/// the root has no readable package name or the file is not under `lib/`.
String? packageImportFor(String packageRoot, String filePath) {
  final pubspec = File('$packageRoot/pubspec.yaml');
  if (!pubspec.existsSync()) return null;

  final packageName = RegExp(r'^name:\s*([^\s#]+)', multiLine: true)
      .firstMatch(pubspec.readAsStringSync())
      ?.group(1);
  if (packageName == null) return null;

  final root = packageRoot.replaceAll('\\', '/');
  final file = filePath.replaceAll('\\', '/');
  final rootPrefix = root.endsWith('/') ? root : '$root/';
  if (!file.startsWith(rootPrefix)) return null;

  final relativePath = file.substring(rootPrefix.length);
  if (!relativePath.startsWith('lib/')) return null;
  return packageImportFromLibPath(packageName, relativePath);
}
