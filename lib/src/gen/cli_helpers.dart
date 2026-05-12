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
          return entity.path;
        }
      } catch (_) {}
    }
  }
  return null;
}
