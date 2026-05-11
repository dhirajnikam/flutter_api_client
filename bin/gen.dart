import 'dart:io';

/// CLI entry point: `dart run flutter_api_client:gen`.
///
/// This is a thin wrapper that explains how to invoke the generators from
/// a project that imports this package. The generators are also exposed as
/// regular Dart classes so projects can call them programmatically:
///
/// ```dart
/// import 'package:flutter_api_client/flutter_api_client.dart';
///
/// void main() {
///   final spec = buildSpec();
///   File('doc/openapi.yaml').writeAsStringSync(OpenApiGenerator(spec).toYaml());
///   File('doc/API_DOCS.md').writeAsStringSync(MarkdownDocGenerator(spec).generate());
///   File('doc/BACKEND_GUIDE.md').writeAsStringSync(
///     BackendGuideGenerator(spec, framework: BackendFramework.fastapi).generate(),
///   );
/// }
/// ```
void main(List<String> args) {
  stdout.writeln('flutter_api_client:gen');
  stdout.writeln('');
  stdout.writeln('Define your spec in your project then run a tiny script:');
  stdout.writeln('');
  stdout.writeln(
    '  import "package:flutter_api_client/flutter_api_client.dart";',
  );
  stdout.writeln('  void main() {');
  stdout.writeln('    final spec = buildSpec(); // your ApiSpec');
  stdout.writeln('    File("doc/openapi.yaml").writeAsStringSync(');
  stdout.writeln('        OpenApiGenerator(spec).toYaml());');
  stdout.writeln('    File("doc/API_DOCS.md").writeAsStringSync(');
  stdout.writeln('        MarkdownDocGenerator(spec).generate());');
  stdout.writeln('    File("doc/BACKEND_GUIDE.md").writeAsStringSync(');
  stdout.writeln('        BackendGuideGenerator(spec).generate());');
  stdout.writeln('  }');
}
