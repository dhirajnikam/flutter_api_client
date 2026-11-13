/// Name of the getter the builder generates next to an `@ApiSpecEntry`
/// variable; the CLI finds and imports the spec through it.
const generatedSpecGetter = r'$generatedSpec';

/// Maps a `lib/`-relative file path (either separator) to its `package:` URI.
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
