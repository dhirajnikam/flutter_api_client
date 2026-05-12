# Gen Command, Annotation, Builder, and Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `@ApiSpecEntry()` annotation + build_runner builder so the package can discover a user's spec, replace the stub `bin/gen.dart` with a full CLI that writes OpenAPI/docs/backend-guide files, and create a Claude Code skill that teaches agents full package expertise.

**Architecture:** Four independent tasks: (1) annotation + `build.yaml` + export, (2) build_runner builder that generates a `$generatedSpec` getter, (3) full `bin/gen.dart` CLI with arg parsing that uses a two-step subprocess to load the generated spec from the user's project, (4) the skill file written to `~/.claude/plugins/user-skills/flutter-api-client/skill.md`. The CLI communicates with the user's project by writing a temporary runner script, executing it via `dart run`, reading stdout as the list of written files, then deleting the runner.

**Tech Stack:** Dart 3, `package:args` for CLI flags, `package:build` + `package:source_gen` for the builder, `dart:io` for subprocess + file I/O. No Flutter dependency in CLI or builder.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/src/gen/api_spec_entry.dart` | Create | `@ApiSpecEntry()` annotation class |
| `lib/src/gen/api_spec_builder.dart` | Create | build_runner builder — scans for `@ApiSpecEntry`, emits `$generatedSpec` getter |
| `lib/src/gen/cli_helpers.dart` | Create | Testable helpers: `parseOnly()`, `findGeneratedSpecFile()` |
| `build.yaml` | Create | Registers the builder with build_runner |
| `pubspec.yaml` | Modify | Add `executables`, `build` + `args` to dependencies, `build_runner` + `source_gen` to dev_dependencies |
| `lib/flutter_api_client.dart` | Modify | Export `api_spec_entry.dart` |
| `bin/gen.dart` | Rewrite | Full CLI: parse args, detect generated file, write temp runner, subprocess, print summary |
| `test/gen_cli_test.dart` | Create | Tests for annotation + `parseOnly` + `findGeneratedSpecFile` |
| `~/.claude/plugins/user-skills/flutter-api-client/skill.md` | Create | Four-section Claude Code skill |

---

### Task 1: `@ApiSpecEntry()` annotation + `build.yaml` + pubspec

**Files:**
- Create: `lib/src/gen/api_spec_entry.dart`
- Modify: `lib/flutter_api_client.dart`
- Create: `build.yaml`
- Modify: `pubspec.yaml`

- [ ] **Step 1: Write the annotation class**

Create `lib/src/gen/api_spec_entry.dart`:

```dart
/// Marks a top-level [ApiSpec] variable for discovery by `dart run flutter_api_client:gen`.
///
/// Usage:
/// ```dart
/// import 'package:flutter_api_client/flutter_api_client.dart';
///
/// @ApiSpecEntry()
/// final mySpec = ApiSpec(
///   title: 'My API',
///   version: '1.0.0',
///   baseUrl: 'https://api.example.com',
/// );
/// ```
class ApiSpecEntry {
  const ApiSpecEntry();
}
```

- [ ] **Step 2: Export the annotation from the barrel**

In `lib/flutter_api_client.dart`, add a `// Gen` section after the `// Spec` exports block:

```dart
// Gen
export 'src/gen/api_spec_entry.dart';
```

- [ ] **Step 3: Create `build.yaml`**

Create `build.yaml` at the project root:

```yaml
builders:
  api_spec_builder:
    import: "package:flutter_api_client/src/gen/api_spec_builder.dart"
    builder_factories: ["apiSpecBuilder"]
    build_extensions: {".dart": [".g.dart"]}
    auto_apply: dependents
    build_to: source
    applies_builders: ["source_gen|combining_builder"]
```

- [ ] **Step 4: Update `pubspec.yaml`**

Add `executables`, `build` + `args` to `dependencies`, and `build_runner` + `source_gen` to `dev_dependencies`. The complete updated sections:

```yaml
executables:
  gen: gen

dependencies:
  http: ^1.2.2
  meta: ^1.12.0
  collection: ^1.18.0
  build: ^2.4.0
  args: ^2.5.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0
  build_runner: ^2.4.0
  source_gen: ^1.5.0
```

- [ ] **Step 5: Run `dart pub get`**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
dart pub get
```

Expected: Resolves without errors.

- [ ] **Step 6: Verify the annotation is importable**

```bash
dart analyze lib/src/gen/api_spec_entry.dart
```

Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/src/gen/api_spec_entry.dart lib/flutter_api_client.dart build.yaml pubspec.yaml pubspec.lock
git commit -m "feat: add @ApiSpecEntry() annotation, build.yaml, update pubspec"
```

---

### Task 2: build_runner builder + annotation tests

**Files:**
- Create: `lib/src/gen/api_spec_builder.dart`
- Create: `test/gen_cli_test.dart`

**Context:** `GeneratorForAnnotation<ApiSpecEntry>` from `package:source_gen` is the cleanest way to hook into the build system. The builder emits a single getter `ApiSpec get $generatedSpec => varName;` alongside the annotated file as a `.g.dart`. The builder is registered via the `build.yaml` created in Task 1.

- [ ] **Step 1: Write tests for the annotation**

Create `test/gen_cli_test.dart`:

```dart
import 'package:flutter_api_client/flutter_api_client.dart';
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
}
```

- [ ] **Step 2: Run to confirm the annotation tests pass**

```bash
flutter test test/gen_cli_test.dart
```

Expected: `All tests passed.`

- [ ] **Step 3: Write the builder**

Create `lib/src/gen/api_spec_builder.dart`:

```dart
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'api_spec_entry.dart';

Builder apiSpecBuilder(BuilderOptions options) =>
    SharedPartBuilder([_ApiSpecGenerator()], 'api_spec_entry');

class _ApiSpecGenerator extends GeneratorForAnnotation<ApiSpecEntry> {
  @override
  String generateForAnnotatedElement(
    dynamic element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    final name = element.name as String;
    return '''
// Generated by flutter_api_client — do not edit.
// Run `dart run build_runner build` to regenerate.

ApiSpec get \$generatedSpec => $name;
''';
  }
}
```

- [ ] **Step 4: Analyze the builder**

```bash
dart analyze lib/src/gen/api_spec_builder.dart
```

Expected: No errors. (Info-level warnings about `dynamic` are acceptable.)

- [ ] **Step 5: Commit**

```bash
git add lib/src/gen/api_spec_builder.dart test/gen_cli_test.dart
git commit -m "feat: add build_runner builder for @ApiSpecEntry discovery"
```

---

### Task 3: Full `bin/gen.dart` CLI

**Files:**
- Create: `lib/src/gen/cli_helpers.dart`
- Rewrite: `bin/gen.dart`
- Modify: `test/gen_cli_test.dart`

**Context:** The CLI cannot import the user's spec at compile time. Strategy:
1. Search cwd recursively for a `.g.dart` containing `$generatedSpec` (written by build_runner).
2. If not found, print a clear error.
3. Write `tool/.flutter_api_client_runner.dart` — a temp script that imports the `.g.dart` and calls the generators, writing files and printing each path to stdout.
4. Run the runner via `dart run tool/.flutter_api_client_runner.dart`.
5. Print formatted summary from runner's stdout.
6. Delete the runner.

The helper functions (`parseOnly`, `findGeneratedSpecFile`) are in a separate file so they can be unit-tested without spawning processes.

- [ ] **Step 1: Add helper tests to `test/gen_cli_test.dart`**

Append inside `main()` in `test/gen_cli_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_api_client/src/gen/cli_helpers.dart';
// (add these imports at the top of the file alongside existing imports)
```

Add these groups inside `main()`:

```dart
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
```

- [ ] **Step 2: Run to confirm they fail (helpers not yet written)**

```bash
flutter test test/gen_cli_test.dart
```

Expected: FAIL — `parseOnly` and `findGeneratedSpecFile` not defined.

- [ ] **Step 3: Create `lib/src/gen/cli_helpers.dart`**

```dart
import 'dart:io';

const _validGenerators = ['openapi', 'reference', 'backend'];

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
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
flutter test test/gen_cli_test.dart
```

Expected: All tests PASS.

- [ ] **Step 5: Rewrite `bin/gen.dart`**

Replace the entire content of `bin/gen.dart` with:

```dart
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

  // 1. Locate the generated spec file.
  final specFile = findGeneratedSpecFile(Directory.current.path);
  if (specFile == null) {
    stderr.writeln(
      '\n  ✗ No generated spec found.\n\n'
      '  Annotate your ApiSpec variable with @ApiSpecEntry() then run:\n'
      '    dart run build_runner build\n',
    );
    exit(1);
  }

  // 2. Build the import path relative to the temp runner location.
  final cwd = Directory.current.path;
  final runnerDir = '$cwd/tool';
  final runnerPath = '$runnerDir/.flutter_api_client_runner.dart';

  // Make specFile path relative to runnerDir for the import.
  final specRelative = _relativePath(from: runnerDir, to: specFile);

  // 3. Write the temp runner.
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

  // 4. Run the temp runner as a subprocess.
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
  final fromUri = Uri.directory(from);
  final toUri = Uri.file(to);
  return fromUri.resolveUri(fromUri.relativize(toUri)).path.isEmpty
      ? toUri.toFilePath()
      : Uri.parse(fromUri.relativize(toUri).toString()).toFilePath();
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
```

- [ ] **Step 6: Analyze CLI and helpers**

```bash
dart analyze bin/gen.dart lib/src/gen/cli_helpers.dart
```

Expected: No errors.

- [ ] **Step 7: Run full test suite**

```bash
flutter test
```

Expected: All tests PASS.

- [ ] **Step 8: Commit**

```bash
git add bin/gen.dart lib/src/gen/cli_helpers.dart test/gen_cli_test.dart
git commit -m "feat: implement full dart run flutter_api_client:gen CLI"
```

---

### Task 4: Claude Code skill

**Files:**
- Create: `~/.claude/plugins/user-skills/flutter-api-client/skill.md`

**Context:** This is a Markdown skill file, not a Dart file. When the user types `/flutter-api-client` in Claude Code (in any project), Claude loads this file and gains full knowledge of the package. The `~/.claude/plugins/user-skills/` path is the standard location for user-level skills.

- [ ] **Step 1: Create the directory**

```bash
mkdir -p ~/.claude/plugins/user-skills/flutter-api-client
```

- [ ] **Step 2: Write the skill file**

Create `~/.claude/plugins/user-skills/flutter-api-client/skill.md` with exactly this content:

```markdown
---
name: flutter-api-client
description: Full expertise for the flutter_api_client package — ApiSpec DSL, ApiResult<T>, gen CLI, all interceptors, auth, GraphQL, MockAdapter, and testing patterns.
---

# flutter_api_client Package Expert

You are an expert on the `flutter_api_client` package (v2.0.0+). Use this skill to write correct, idiomatic code that uses the package.

---

## Section 1 — Writing an `ApiSpec`

An `ApiSpec` is the single source of truth for mocks, OpenAPI, and docs.

```dart
import 'package:flutter_api_client/flutter_api_client.dart';

@ApiSpecEntry()              // marks this for `dart run flutter_api_client:gen`
final mySpec = ApiSpec(
  title: 'My API',
  version: '1.0.0',
  baseUrl: 'https://api.example.com',
);

void buildSpec() {
  mySpec.group('Users', (g) {
    g.endpoint('GET /users',
      summary: 'List all users',
      queryParams: {'page': Schema.integer(), 'limit': Schema.integer()},
      responses: [ResponseExample.ok({'items': [], 'total': 0})],
    );
    g.endpoint('POST /users',
      summary: 'Create user',
      request: RequestExample({'name': 'Alice', 'email': 'a@b.com'}),
      responses: [
        ResponseExample.created({'id': 1, 'name': 'Alice'}),
        ResponseExample.error(422, {'message': 'Validation failed'}),
      ],
    );
    g.endpoint('GET /users/{id}',
      pathParams: {'id': Schema.integer()},
      responses: [ResponseExample.ok({'id': 1, 'name': 'Alice'})],
    );
    g.endpoint('DELETE /users/{id}',
      pathParams: {'id': Schema.integer()},
      responses: [ResponseExample.noContent()],
    );
  });

  mySpec.graphql((g) {
    g.query('Me',
      document: r'query Me { me { id name } }',
      responseExample: {'me': {'id': 1, 'name': 'Alice'}},
    );
    g.mutation('Login',
      document: r'mutation Login($email: String!, $password: String!) { login(email: $email, password: $password) { token } }',
      variables: {
        'email': Schema.string(required: true, format: 'email'),
        'password': Schema.string(required: true, minLength: 8),
      },
      responseExample: {'login': {'token': 'jwt'}},
      errors: [GraphQLErrorExample(
        message: 'Invalid credentials',
        extensions: {'code': 'UNAUTHENTICATED'},
      )],
    );
  });
}
```

**Schema factories:** `Schema.string`, `Schema.integer`, `Schema.number`, `Schema.boolean`, `Schema.object`, `Schema.array` — all accept `required: bool`.

**ResponseExample factories:** `.ok(body)` → 200, `.created(body)` → 201, `.noContent()` → 204, `.error(status, body)` → any 4xx/5xx.

---

## Section 2 — Running the generator

**One-time setup after annotating your spec:**

```bash
dart pub add --dev build_runner source_gen
dart run build_runner build
```

This generates `lib/your_file.g.dart` containing `ApiSpec get $generatedSpec => mySpec;`.

**Generate docs:**

```bash
dart run flutter_api_client:gen                            # all outputs → docs/api/
dart run flutter_api_client:gen --output docs/backend/    # custom dir
dart run flutter_api_client:gen --framework express        # Express.js snippets
dart run flutter_api_client:gen --framework fastapi        # FastAPI snippets
dart run flutter_api_client:gen --only openapi             # just openapi.json + openapi.yaml
dart run flutter_api_client:gen --only reference,backend  # skip openapi
dart run flutter_api_client:gen --no-json                  # YAML only
dart run flutter_api_client:gen --dry-run                  # preview without writing
```

**Default output structure:**

```
docs/api/
  openapi.json
  openapi.yaml
  api-reference.md
  backend-guide.md
```

**Error: no generated spec found** → run `dart run build_runner build` first.

**Programmatic alternative (no annotation needed):**

```dart
final gen = OpenApiGenerator(spec);
File('docs/api/openapi.yaml').writeAsStringSync(gen.toYaml());
File('docs/api/openapi.json').writeAsStringSync(gen.toJsonString());
File('docs/api/api-reference.md').writeAsStringSync(MarkdownDocGenerator(spec).generate());
File('docs/api/backend-guide.md').writeAsStringSync(
  BackendGuideGenerator(spec, framework: BackendFramework.express).generate(),
);
```

---

## Section 3 — Using `ApiResult<T>`

Every HTTP method returns `ApiResult<T>` — a sealed class with `Success<T>` and `Failure<T>`.

**Simple usage:**

```dart
final result = await client.get<User>('users/me', decoder: User.fromJson);
if (result.isSuccess) {
  print(result.data!.name);
} else {
  showSnackbar(result.errorMessage!);  // human-readable
  print(result.statusCode);            // int? — null for network errors
}
```

**Typed error handling:**

```dart
result.when(
  success: (user) => updateState(user),
  failure: (err) => switch (err) {
    HttpError(statusCode: 401) => logout(),
    HttpError(statusCode: 422, :final body) => showValidationErrors(body),
    NetworkError() => showOfflineBanner(),
    TimeoutError() => showRetryButton(),
    CancelError() => null,
    _ => showSnackbar(err.message),
  },
);
```

**Chaining with `.map()`:**

```dart
final nameResult = result.map((user) => user.name); // ApiResult<String>
```

**All five HTTP methods:**

```dart
await client.get<T>(endpoint, {decoder, options, includeToken});
await client.post<T>(endpoint, body, {decoder, isMultipart, options});
await client.put<T>(endpoint, body, {decoder, isMultipart, options});
await client.patch<T>(endpoint, body, {decoder, isMultipart, options});
await client.delete<T>(endpoint, {decoder, options});
```

**`RequestOptions`:**

```dart
RequestOptions(
  queryParameters: {'page': '1', 'limit': '20'},
  timeout: Duration(seconds: 10),
  cancelToken: CancelToken(),
  responseType: ResponseType.json,   // .bytes, .plainText, .stream
  headers: {'X-Custom': 'value'},
  baseUrlOverride: 'https://other.api',
)
```

**`ApiException` hierarchy:** `HttpError` (`.statusCode`, `.body`, `.headers`), `NetworkError`, `TimeoutError`, `CancelError`, `ParseError`, `UnknownError`.

---

## Section 4 — Full package features

**Creating an `ApiClient`:**

```dart
// Token callback
final client = ApiClient(ApiClientConfig.withToken(
  baseUrl: 'https://api.example.com',
  getAccessToken: () async => await storage.read('access_token'),
  refreshToken: () async => await refreshFlow(),
));

// TokenStorage
final client = ApiClient(ApiClientConfig.withStorage(
  baseUrl: 'https://api.example.com',
  tokenStorage: MemoryTokenStorage(accessToken: 'tok'),
));

// Test (no auth)
final client = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com',
  adapter: MockAdapter(),
));
```

**Interceptors:**

```dart
ApiClientConfig(
  baseUrl: '...',
  interceptors: [
    RetryInterceptor(RetryPolicy(maxAttempts: 3, baseDelay: Duration(seconds: 1))),
    CacheInterceptor(MemoryCacheStore(), defaultPolicy: CachePolicy.networkFirst),
    DedupInterceptor(),
    PrettyLogger(),
    CurlLogger(),
    OfflineQueueInterceptor(
      store: InMemoryOfflineQueueStore(),
      isOnline: () => Connectivity().checkConnectivity() != ConnectivityResult.none,
    ),
  ],
)
```

**MockAdapter for unit tests:**

```dart
final mock = MockAdapter();
mock.on('GET', '/users', statusCode: 200, body: [{'id': 1}]);
mock.on('POST', RegExp(r'^/users$'), statusCode: 201, body: {'id': 2});
mock.onRequest('GET', '/slow', (req) async {
  await Future.delayed(Duration(milliseconds: 50));
  return AdapterResponse(statusCode: 200, headers: {}, bodyBytes: Uint8List(0));
});
```

**SpecMockAdapter (spec-driven tests):**

```dart
final client = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com',
  adapter: SpecMockAdapter(
    mySpec,
    statusOverrides: {'DELETE /users/{id}': 404},
  ),
));
// All endpoints automatically return their responseExample.
// statusOverrides forces specific endpoints to error.
```

**GraphQLClient:**

```dart
final gql = GraphQLClient(client, endpoint: '/graphql');

final res = await gql.query<String>(
  r'query Me { me { id name } }',
  decoder: (data) => (data as Map)['me']['name'] as String,
);
if (res.isSuccess) print(res.data);

final mutRes = await gql.mutation<Map<String, dynamic>>(
  r'mutation Login($e: String!, $p: String!) { login(email: $e, password: $p) { token } }',
  variables: {'e': 'user@example.com', 'p': 'secret'},
);
if (mutRes.errors.isNotEmpty) print(mutRes.errors.first.message);
```

**CancelToken:**

```dart
final token = CancelToken();
final future = client.get('data', options: RequestOptions(cancelToken: token));
token.cancel('user navigated away');
final result = await future; // Failure(CancelError(...))
```

**Auth storage:**

```dart
MemoryTokenStorage(accessToken: 'tok', refreshToken: 'ref')
CachedTokenStorage(inner)  // wraps any TokenStorage with in-memory cache
```
```

- [ ] **Step 3: Verify the skill file was created**

```bash
head -6 ~/.claude/plugins/user-skills/flutter-api-client/skill.md
```

Expected:
```
---
name: flutter-api-client
description: Full expertise for the flutter_api_client package...
---
```

- [ ] **Step 4: Run the full test suite**

```bash
flutter test
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/gen/ build.yaml bin/gen.dart test/gen_cli_test.dart pubspec.yaml pubspec.lock
git commit -m "feat: add Claude Code skill for flutter_api_client package expertise"
```

---

### Task 5: End-to-end smoke test

**Files:**
- Create: `example/lib/my_spec.dart`

**Context:** Verify the full workflow — annotate a spec, run build_runner, run the CLI. Uses the existing `example/` project.

- [ ] **Step 1: Create a minimal annotated spec in the example**

Create `example/lib/my_spec.dart`:

```dart
import 'package:flutter_api_client/flutter_api_client.dart';

@ApiSpecEntry()
final mySpec = ApiSpec(
  title: 'Example API',
  version: '1.0.0',
  baseUrl: 'https://dummyjson.com',
)..group('Users', (g) {
    g.endpoint(
      'GET /users',
      summary: 'List users',
      responses: [ResponseExample.ok({'users': [], 'total': 0})],
    );
    g.endpoint(
      'GET /users/{id}',
      pathParams: {'id': Schema.integer()},
      responses: [ResponseExample.ok({'id': 1, 'firstName': 'Alice'})],
    );
  });
```

- [ ] **Step 2: Add build_runner to the example's pubspec**

In `example/pubspec.yaml`, add under `dev_dependencies`:

```yaml
dev_dependencies:
  build_runner: ^2.4.0
  source_gen: ^1.5.0
```

- [ ] **Step 3: Run build_runner in the example directory**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client/example
dart pub get
dart run build_runner build --delete-conflicting-outputs
```

Expected: Creates `example/lib/my_spec.g.dart` containing `$generatedSpec`.

- [ ] **Step 4: Dry-run the CLI**

```bash
dart run flutter_api_client:gen --dry-run
```

Expected output:
```
flutter_api_client gen
─────────────────────────────────────────────
  (dry-run) docs/api/openapi.json  (x.x KB)
  (dry-run) docs/api/openapi.yaml  (x.x KB)
  (dry-run) docs/api/api-reference.md  (x.x KB)
  (dry-run) docs/api/backend-guide.md  (x.x KB)
Done. 4 files would be written.
─────────────────────────────────────────────
```

- [ ] **Step 5: Run for real and verify output**

```bash
dart run flutter_api_client:gen --output /tmp/fac_smoke
ls /tmp/fac_smoke/
head -5 /tmp/fac_smoke/openapi.yaml
```

Expected `ls` output: `api-reference.md  backend-guide.md  openapi.json  openapi.yaml`

Expected `head` output starts with:
```yaml
openapi: 3.1.0
info:
  title: Example API
  version: 1.0.0
```

- [ ] **Step 6: Return to project root and commit**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
git add example/lib/my_spec.dart
git commit -m "example: add @ApiSpecEntry spec for smoke-testing gen CLI"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Covered by |
|-----------------|------------|
| `@ApiSpecEntry()` annotation class | Task 1, Step 1 |
| Exported from barrel `flutter_api_client.dart` | Task 1, Step 2 |
| `build.yaml` declaring the builder | Task 1, Step 3 |
| `build`, `args` in dependencies; `build_runner`, `source_gen` in dev | Task 1, Step 4 |
| `executables: gen: gen` in pubspec | Task 1, Step 4 |
| Builder generates `$generatedSpec` getter | Task 2, Step 3 |
| `--output` / `--only` / `--framework` / `--no-json` / `--no-yaml` / `--dry-run` flags | Task 3, Step 5 |
| Error when no `.g.dart` with `$generatedSpec` found | Task 3, Step 5 |
| Subprocess temp-runner pattern | Task 3, Step 5 |
| Formatted console output with ✓ lines | Task 3, Step 5 |
| Skill — Section 1: Writing ApiSpec | Task 4, Step 2 |
| Skill — Section 2: Running generator | Task 4, Step 2 |
| Skill — Section 3: Using ApiResult<T> | Task 4, Step 2 |
| Skill — Section 4: Full package features | Task 4, Step 2 |
| End-to-end smoke test | Task 5 |

**Placeholder scan:** No TBD, TODO, or vague steps. All code blocks are complete.

**Type consistency:** `ApiSpecEntry` is consistent across all tasks. `$generatedSpec` getter name is consistent between Task 2 (emitted by builder), Task 3 `findGeneratedSpecFile` (searches for it), and Task 5 (generated by build_runner). `parseOnly` and `findGeneratedSpecFile` are defined in Task 3 Step 3 and tested in Task 3 Step 1. `BackendFramework.values.firstWhere` usage in the runner matches the `enum BackendFramework` definition in `lib/src/spec/backend_guide_generator.dart:578`.
