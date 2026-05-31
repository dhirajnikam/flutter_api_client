import 'dart:io';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_api_client/src/gen/cli_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('@ApiSpecEntry annotation', () {
    test('can be instantiated as const', () {
      const entry = ApiSpecEntry();
      expect(entry, isNotNull);
    });

    test('two const instances are identical (const canonicalization)', () {
      const a = ApiSpecEntry();
      const b = ApiSpecEntry();
      expect(identical(a, b), true);
    });
  });

  group('parseOnly', () {
    test('returns all three generators when null', () {
      expect(parseOnly(null), containsAll(['openapi', 'reference', 'backend']));
    });

    test('returns filtered list for valid subset', () {
      final result = parseOnly('openapi,reference');
      expect(result, equals(['openapi', 'reference']));
      expect(result, isNot(contains('backend')));
    });

    test('throws ArgumentError for unknown generator name', () {
      expect(() => parseOnly('openapi,unknown'), throwsArgumentError);
    });

    test('single valid name works', () {
      expect(parseOnly('backend'), equals(['backend']));
    });

    test("accepts 'tests' as a valid generator", () {
      expect(parseOnly('tests'), equals(['tests']));
    });

    test("accepts 'tests' mixed with openapi", () {
      expect(parseOnly('openapi,tests'), containsAll(['openapi', 'tests']));
    });
  });

  group('findGeneratedSpecFile', () {
    test('returns null when no .g.dart with \$generatedSpec exists', () async {
      final dir = await Directory.systemTemp.createTemp('gen_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(findGeneratedSpecFile(dir.path), isNull);
    });

    test('returns path when matching .g.dart exists', () async {
      final dir = await Directory.systemTemp.createTemp('gen_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/api_spec.g.dart');
      f.writeAsStringSync('ApiSpec get \$generatedSpec => mySpec;');
      expect(findGeneratedSpecFile(dir.path), equals(f.path));
    });

    test('returns null for .g.dart without \$generatedSpec', () async {
      final dir = await Directory.systemTemp.createTemp('gen_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/other.g.dart').writeAsStringSync('// unrelated');
      expect(findGeneratedSpecFile(dir.path), isNull);
    });
  });

  group('packageImportFor', () {
    test('returns a package import for a file under lib/', () async {
      final dir = await Directory.systemTemp.createTemp('gen_pkg_');
      addTearDown(() => dir.deleteSync(recursive: true));

      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: sample_pkg\n');
      final libDir = Directory('${dir.path}/lib')..createSync(recursive: true);
      final specFile = File('${libDir.path}/my_spec.dart')..writeAsStringSync('');

      expect(
        packageImportFor(dir.path, specFile.path),
        'package:sample_pkg/my_spec.dart',
      );
    });
  });

  group('buildApiSpecSmokeTestSource', () {
    test('emits analyzer-safe scaffold content', () {
      final source = buildApiSpecSmokeTestSource(
        importPath: 'package:sample_pkg/my_spec.dart',
        specSymbol: 'mySpec',
      );

      expect(source, contains('ignore_for_file: depend_on_referenced_packages'));
      expect(
        source,
        contains("import 'package:sample_pkg/my_spec.dart';"),
      );
      expect(source, isNot(contains("import 'package:flutter_api_client/flutter_api_client.dart';")));
      expect(source, contains('expect(mySpec.endpoints, isNotEmpty);'));
    });
  });
}
