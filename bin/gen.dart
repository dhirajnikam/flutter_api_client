import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_api_client/src/gen/cli_helpers.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('output', abbr: 'o', defaultsTo: 'docs/api',
        help: 'Output directory for generated files')
    ..addOption('only',
        help: 'Comma-separated subset to generate: openapi, reference, backend')
    ..addOption('framework', defaultsTo: 'none',
        allowed: ['none', 'express', 'fastapi', 'gin'],
        help: 'Backend framework for code snippets in backend-guide.md')
    ..addFlag('no-json', negatable: false,
        help: 'Skip openapi.json (YAML only)')
    ..addFlag('no-yaml', negatable: false,
        help: 'Skip openapi.yaml (JSON only)')
    ..addFlag('dry-run', negatable: false,
        help: 'Print output paths without writing files')
    ..addFlag('help', abbr: 'h', negatable: false,
        help: 'Show this help');

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

  final outputDir = parsed['output'] as String;
  final framework = parsed['framework'] as String;
  final noJson = parsed['no-json'] as bool;
  final noYaml = parsed['no-yaml'] as bool;
  final dryRun = parsed['dry-run'] as bool;

  // Locate the generated spec file.
  final specFile = findGeneratedSpecFile(Directory.current.path);
  if (specFile == null) {
    stderr.writeln(
      '\n  ✗ No generated spec found.\n\n'
      '  Annotate your ApiSpec variable with @ApiSpecEntry() then run:\n'
      '    dart run build_runner build\n',
    );
    exit(1);
  }

  // Build the import path relative to the temp runner location.
  final cwd = Directory.current.path;
  final runnerDir = '$cwd/tool';
  final runnerPath = '$runnerDir/.flutter_api_client_runner.dart';

  // The generated spec file is a `.g.dart` part file; the runner must import
  // the parent `.dart` file that contains the actual declarations.
  final parentSpecFile = specFile.endsWith('.g.dart')
      ? specFile.replaceFirst(RegExp(r'\.g\.dart$'), '.dart')
      : specFile;

  // Make specFile path relative to runnerDir for the import.
  final specRelative = _relativePath(from: runnerDir, to: parentSpecFile);

  // Write the temp runner.
  Directory(runnerDir).createSync(recursive: true);
  File(runnerPath).writeAsStringSync(
    _runnerSource(
      specRelative: specRelative,
      outputDir: outputDir,
      framework: framework,
      generators: generators,
      noJson: noJson,
      noYaml: noYaml,
      dryRun: dryRun,
    ),
  );

  stdout.writeln('\nflutter_api_client gen');
  stdout.writeln('─' * 45);

  // Run the temp runner as a subprocess.
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
  stdout.writeln('─' * 45);
}

String _relativePath({required String from, required String to}) {
  // Compute a relative path from [from] directory to [to] file.
  final fromParts = from.split('/');
  final toParts = to.split('/');

  // Find common prefix length.
  var common = 0;
  while (common < fromParts.length &&
      common < toParts.length &&
      fromParts[common] == toParts[common]) {
    common++;
  }

  // For each remaining segment in [from], go up one level.
  final ups = fromParts.length - common;
  final rel = <String>[
    for (var i = 0; i < ups; i++) '..',
    ...toParts.sublist(common),
  ];
  return rel.join('/');
}

String _runnerSource({
  required String specRelative,
  required String outputDir,
  required String framework,
  required List<String> generators,
  required bool noJson,
  required bool noYaml,
  required bool dryRun,
}) {
  final genOpenapi = generators.contains('openapi');
  final genReference = generators.contains('reference');
  final genBackend = generators.contains('backend');

  return '''
// AUTO-GENERATED — deleted after use. Do not commit.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'package:flutter_api_client/flutter_api_client.dart';
import '${specRelative.replaceAll(r'\\', '/')}';

void main() {
  final spec = \$generatedSpec;
  final outDir = Directory('$outputDir');
  if (!${dryRun}) outDir.createSync(recursive: true);

  var count = 0;

  void write(String name, String content) {
    final path = '\${outDir.path}/\$name';
    final kb = (content.length / 1024).toStringAsFixed(1);
    if (${dryRun}) {
      stdout.writeln('  (dry-run) \$path  (\$kb KB)');
    } else {
      File(path).writeAsStringSync(content);
      stdout.writeln('  ✓ \$path  (\$kb KB)');
    }
    count++;
  }

  if (${genOpenapi}) {
    final gen = OpenApiGenerator(spec);
    if (!${noJson}) write('openapi.json', gen.toJsonString());
    if (!${noYaml}) write('openapi.yaml', gen.toYaml());
  }
  if (${genReference}) {
    write('api-reference.md', MarkdownDocGenerator(spec).generate());
  }
  if (${genBackend}) {
    final fw = BackendFramework.values.firstWhere(
      (f) => f.name == '$framework',
      orElse: () => BackendFramework.none,
    );
    write('backend-guide.md',
        BackendGuideGenerator(spec, framework: fw).generate());
  }

  stdout.writeln(
    'Done. \$count file\${count == 1 ? "" : "s"} '
    '\${${dryRun} ? "would be " : ""}written.',
  );
}
''';
}
