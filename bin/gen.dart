import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_api_client/src/gen/cli_helpers.dart';
import 'package:flutter_api_client/src/gen/package_import.dart';
import 'package:flutter_api_client/src/spec/backend_guide_generator.dart';

const _testPath = 'test/api_spec_test.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('output',
        abbr: 'o',
        defaultsTo: 'docs/api',
        help: 'Output directory for generated files')
    ..addOption('only',
        help: 'Comma-separated subset to generate: '
            '${validGenerators.join(', ')}')
    // Each value is spliced into the runner as `BackendFramework.<value>`.
    ..addOption('framework',
        defaultsTo: 'none',
        allowed: [for (final f in BackendFramework.values) EnumName(f).name],
        help: 'Backend framework for code snippets in backend-guide.md')
    ..addFlag('no-json',
        negatable: false, help: 'Skip openapi.json (YAML only)')
    ..addFlag('no-yaml',
        negatable: false, help: 'Skip openapi.yaml (JSON only)')
    ..addFlag('tests',
        negatable: false, help: 'Shorthand for --only tests; writes $_testPath')
    ..addFlag('dry-run',
        negatable: false, help: 'Print output paths without writing files')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help');

  late ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error: $e\n');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (parsed['help'] as bool) {
    stdout.writeln('dart run flutter_api_client:gen [options]\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  List<String> generators;
  try {
    generators = parseOnly(parsed['only'] as String?);
  } on ArgumentError catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }
  if (parsed['tests'] as bool) generators = ['tests'];

  final dryRun = parsed['dry-run'] as bool;
  final cwd = Directory.current.path;

  final specFile = findGeneratedSpecFile(cwd);
  if (specFile == null) {
    stderr.writeln(
      '\n  ✗ No generated spec found.\n\n'
      '  Annotate your ApiSpec variable with @ApiSpecEntry() then run:\n'
      '    dart run build_runner build\n',
    );
    exit(1);
  }

  final runnerDir = '$cwd/tool';
  final runnerPath = '$runnerDir/.flutter_api_client_runner.dart';

  // The generated spec file is a `.g.dart` part file; the runner must import
  // the parent `.dart` file that contains the actual declarations.
  final parentSpecFile = specFile.replaceFirst(RegExp(r'\.g\.dart$'), '.dart');

  Directory(runnerDir).createSync(recursive: true);
  File(runnerPath).writeAsStringSync(
    _runnerSource(
      specImport: _relativePath(from: runnerDir, to: parentSpecFile),
      generatedTestImport: packageImportFor(cwd, parentSpecFile) ??
          _relativePath(from: '$cwd/test', to: parentSpecFile),
      outputDir: parsed['output'] as String,
      framework: parsed['framework'] as String,
      generators: generators,
      noJson: parsed['no-json'] as bool,
      noYaml: parsed['no-yaml'] as bool,
      dryRun: dryRun,
    ),
  );

  stdout.writeln('\nflutter_api_client gen');
  stdout.writeln('─' * 45);

  ProcessResult result;
  try {
    result = await Process.run(
      Platform.resolvedExecutable,
      ['run', runnerPath],
      workingDirectory: cwd,
    );
  } finally {
    try {
      File(runnerPath).deleteSync();
    } catch (_) {}
  }

  if (result.exitCode != 0) {
    stderr.writeln((result.stderr as String).trim());
    exit(result.exitCode);
  }

  stdout.write(result.stdout);

  // Normalise the generated Dart test with the real formatter. The generator
  // aims for `dart format`-clean output, but long inline body literals can
  // still exceed the line limit; running the SDK formatter (already available
  // since the user invoked `dart run`) guarantees the emitted file is clean.
  if (generators.contains('tests') &&
      !dryRun &&
      File('$cwd/$_testPath').existsSync()) {
    final fmt = await Process.run(
      Platform.resolvedExecutable,
      ['format', _testPath],
      workingDirectory: cwd,
    );
    if (fmt.exitCode == 0) {
      stdout.writeln('  ✓ formatted $_testPath');
    }
  }

  stdout.writeln('─' * 45);
}

/// The relative path from the [from] directory to the [to] file.
String _relativePath({required String from, required String to}) {
  // Normalise separators first: `Directory.current.path` is backslash-based on
  // Windows, so splitting on '/' alone would treat the whole path as one
  // segment and compute a wrong relative import.
  final fromParts = from.replaceAll('\\', '/').split('/');
  final toParts = to.replaceAll('\\', '/').split('/');

  var common = 0;
  while (common < fromParts.length &&
      common < toParts.length &&
      fromParts[common] == toParts[common]) {
    common++;
  }

  return [
    for (var i = common; i < fromParts.length; i++) '..',
    ...toParts.sublist(common),
  ].join('/');
}

String _runnerSource({
  required String specImport,
  required String generatedTestImport,
  required String outputDir,
  required String framework,
  required List<String> generators,
  required bool noJson,
  required bool noYaml,
  required bool dryRun,
}) {
  return '''
// AUTO-GENERATED — deleted after use. Do not commit.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'package:flutter_api_client/flutter_api_client.dart';
import '$specImport';

void main() {
  final spec = $generatedSpecGetter;
  if (!$dryRun) Directory('$outputDir').createSync(recursive: true);

  var count = 0;

  void write(String path, String content) {
    final kb = (content.length / 1024).toStringAsFixed(1);
    if ($dryRun) {
      stdout.writeln('  (dry-run) \$path  (\$kb KB)');
    } else {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
      stdout.writeln('  ✓ \$path  (\$kb KB)');
    }
    count++;
  }

  if (${generators.contains('openapi')}) {
    final gen = OpenApiGenerator(spec);
    if (!$noJson) write('$outputDir/openapi.json', gen.toJsonString());
    if (!$noYaml) write('$outputDir/openapi.yaml', gen.toYaml());
  }
  if (${generators.contains('reference')}) {
    write('$outputDir/api-reference.md', MarkdownDocGenerator(spec).generate());
  }
  if (${generators.contains('backend')}) {
    write(
      '$outputDir/backend-guide.md',
      BackendGuideGenerator(spec, framework: BackendFramework.$framework)
          .generate(),
    );
  }
  if (${generators.contains('tests')}) {
    write(
      '$_testPath',
      TestGenerator(
        spec,
        specImport: '$generatedTestImport',
        specSymbol: r'$generatedSpecGetter',
      ).generate(),
    );
  }

  stdout.writeln(
    'Done. \$count file\${count == 1 ? "" : "s"} '
    '\${$dryRun ? "would be " : ""}written.',
  );
}
''';
}
