# Test Automation, DX & Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add build-runner test scaffold generation, CLI `--only tests` output, and a docs overhaul (README quick-start, API_SERVICES_GUIDE updated to ApiResult<T>, new TESTING.md).

**Architecture:** `TestGenerator` mirrors `MarkdownDocGenerator` — a pure `generate() → String` class. The build-runner builder `_ApiSpecTestGenerator` emits a standalone `.test.g.dart` file (not a `part of`). The CLI wires `TestGenerator` the same way it wires `OpenApiGenerator`. Docs are plain Markdown edits with no code dependency.

**Tech Stack:** Dart 3, `build` + `source_gen` (already in deps), `flutter_test` (dev dep), `args` (already in deps).

---

## File Map

| File | Action |
|------|--------|
| `lib/src/spec/test_generator.dart` | **Create** — `TestGenerator` class |
| `lib/src/gen/api_spec_builder.dart` | **Modify** — add `_ApiSpecTestGenerator` + `apiSpecTestBuilder` factory |
| `build.yaml` | **Modify** — register new builder |
| `lib/src/gen/cli_helpers.dart` | **Modify** — add `'tests'` to `_validGenerators` |
| `bin/gen.dart` | **Modify** — add `--tests` flag + `TestGenerator` wiring |
| `lib/flutter_api_client.dart` | **Modify** — export `TestGenerator` |
| `test/test_generator_test.dart` | **Create** — unit tests for `TestGenerator` |
| `test/gen_cli_test.dart` | **Modify** — extend `parseOnly` tests for `'tests'` |
| `README.md` | **Modify** — 3-step quick-start section |
| `API_SERVICES_GUIDE.md` | **Modify** — replace `CustomApiResponse` with `ApiResult<T>` |
| `TESTING.md` | **Create** — testing cheat-sheet |

---

## Task 1: TestGenerator class (TDD)

**Files:**
- Create: `lib/src/spec/test_generator.dart`
- Create: `test/test_generator_test.dart`
- Modify: `lib/flutter_api_client.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/test_generator_test.dart`:

```dart
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

ApiSpec _minimalSpec() => ApiSpec(
      title: 'Test API',
      version: '1.0.0',
      baseUrl: 'https://api.example.com',
    )..group('Users', (g) {
        g.endpoint(
          'GET /users',
          summary: 'List users',
          responses: [ResponseExample.ok({'users': []})],
        );
        g.endpoint(
          'GET /users/{id}',
          pathParams: {'id': Schema.integer(required: true)},
          responses: [ResponseExample.ok({'id': 1, 'name': 'Alice'})],
        );
      });

ApiSpec _authSpec() => ApiSpec(
      title: 'Auth API',
      version: '1.0.0',
      baseUrl: 'https://api.example.com',
    )..group('Auth', (g) {
        g.endpoint(
          'POST /auth/login',
          auth: false,
          request: RequestExample(
            body: {'email': 'a@b.com', 'password': 'secret'},
            schema: Schema.object({
              'email': Schema.string(required: true),
              'password': Schema.string(minLength: 8, required: true),
            }),
          ),
          responses: [
            ResponseExample.ok({'token': 'jwt'}),
            ResponseExample.error(401, {'message': 'invalid credentials'}),
          ],
        );
      });

ApiSpec _protectedSpec() => ApiSpec(
      title: 'Protected API',
      version: '1.0.0',
      baseUrl: 'https://api.example.com',
    )..group('Items', (g) {
        g.endpoint(
          'POST /items',
          auth: true,
          responses: [ResponseExample.created({'id': 1})],
        );
      });

void main() {
  group('TestGenerator', () {
    test('output contains void main', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('void main()'));
    });

    test('contains flutter_test import', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains("import 'package:flutter_test/flutter_test.dart'"));
    });

    test('contains flutter_api_client import', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains("import 'package:flutter_api_client/flutter_api_client.dart'"));
    });

    test('emits a group per tag', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains("group('Users'"));
    });

    test('emits happy path test for each endpoint', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('GET /users — happy path'));
      expect(out, contains('GET /users/{id} — happy path'));
    });

    test('substitutes concrete value for path param in URL', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains("'users/1'"));
    });

    test('emits schema validation test when request.schema present', () {
      final out = TestGenerator(_authSpec()).generate();
      expect(out, contains('schema validation'));
      expect(out, contains('statusCode, 422'));
    });

    test('emits auth override test when auth == true', () {
      final out = TestGenerator(_protectedSpec()).generate();
      expect(out, contains('auth required'));
      expect(out, contains('statusCode, 401'));
    });

    test('emits error response tests for non-2xx responses', () {
      final out = TestGenerator(_authSpec()).generate();
      expect(out, contains('returns 401'));
    });

    test('no auth override test when auth == false', () {
      final out = TestGenerator(_authSpec()).generate();
      expect(out, isNot(contains('auth required')));
    });

    test('uses baseUrl from spec', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('https://api.example.com'));
    });

    test('includes GENERATED CODE header', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('GENERATED CODE - DO NOT MODIFY BY HAND'));
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
dart test test/test_generator_test.dart
```

Expected: FAIL — `TestGenerator` not found.

- [ ] **Step 3: Implement TestGenerator**

Create `lib/src/spec/test_generator.dart`:

```dart
import 'api_spec.dart';
import 'examples.dart';

/// Generates a complete, runnable `*_test.dart` from an [ApiSpec].
class TestGenerator {
  TestGenerator(this.spec);

  final ApiSpec spec;

  String generate() {
    final buf = StringBuffer();
    buf.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buf.writeln('// Regenerate: dart run flutter_api_client:gen --only tests');
    buf.writeln();
    buf.writeln("import 'package:flutter_api_client/flutter_api_client.dart';");
    buf.writeln("import 'package:flutter_test/flutter_test.dart';");
    buf.writeln();

    final byTag = <String, List<EndpointSpec>>{};
    for (final ep in spec.endpoints) {
      byTag.putIfAbsent(ep.tag ?? 'General', () => []).add(ep);
    }

    buf.writeln('void main() {');
    byTag.forEach((tag, endpoints) {
      buf.writeln("  group('$tag', () {");
      for (final ep in endpoints) {
        _writeEndpointTests(buf, ep);
      }
      buf.writeln('  });');
      buf.writeln();
    });
    buf.writeln('}');
    return buf.toString();
  }

  void _writeEndpointTests(StringBuffer buf, EndpointSpec ep) {
    final baseUrl = spec.baseUrl;
    final methodKey = '${ep.method} ${ep.path}';
    final concretePath = ep.path
        .replaceAllMapped(RegExp(r'\{[^}]+\}'), (_) => '1')
        .replaceFirst(RegExp(r'^/'), '');

    // Happy path
    buf.writeln("    test('${ep.method} ${ep.path} — happy path', () async {");
    buf.writeln(_clientSetup(baseUrl, ''));
    buf.writeln(_callLine(ep, concretePath));
    buf.writeln('      expect(res.isSuccess, true);');
    buf.writeln('    });');
    buf.writeln();

    // Schema validation failure
    if (ep.request?.schema != null) {
      buf.writeln("    test('${ep.method} ${ep.path} — schema validation rejects bad body', () async {");
      buf.writeln(_clientSetup(baseUrl, ''));
      final method = ep.method.toLowerCase();
      buf.writeln("      final res = await client.$method<dynamic>('$concretePath', <String, dynamic>{});");
      buf.writeln('      expect(res.statusCode, 422);');
      buf.writeln('    });');
      buf.writeln();
    }

    // Auth required
    if (ep.auth) {
      buf.writeln("    test('${ep.method} ${ep.path} — auth required returns 401', () async {");
      buf.writeln(_clientSetup(baseUrl, ", statusOverrides: const {'$methodKey': 401}"));
      buf.writeln(_callLine(ep, concretePath));
      buf.writeln('      expect(res.statusCode, 401);');
      buf.writeln('    });');
      buf.writeln();
    }

    // Explicit error responses
    for (final r in ep.responses.where((r) => !r.isSuccess)) {
      buf.writeln("    test('${ep.method} ${ep.path} — returns ${r.statusCode}', () async {");
      buf.writeln(_clientSetup(baseUrl, ", statusOverrides: const {'$methodKey': ${r.statusCode}}"));
      buf.writeln(_callLine(ep, concretePath));
      buf.writeln('      expect(res.statusCode, ${r.statusCode});');
      buf.writeln('    });');
      buf.writeln();
    }
  }

  String _clientSetup(String baseUrl, String overrides) => '''      final client = ApiClient(ApiClientConfig.test(
        baseUrl: '$baseUrl',
        adapter: SpecMockAdapter(spec$overrides),
      ));''';

  String _callLine(EndpointSpec ep, String path) {
    final method = ep.method.toLowerCase();
    if (method == 'get' || method == 'delete' || method == 'head') {
      return "      final res = await client.$method<dynamic>('$path');";
    }
    final body = ep.request?.body;
    final literal = body != null ? _dartLiteral(body) : '<String, dynamic>{}';
    return "      final res = await client.$method<dynamic>('$path', $literal);";
  }

  String _dartLiteral(Object? value) {
    if (value == null) return 'null';
    if (value is String) return "'$value'";
    if (value is num || value is bool) return '$value';
    if (value is Map) {
      final entries = value.entries
          .map((e) => "'${e.key}': ${_dartLiteral(e.value)}")
          .join(', ');
      return '{$entries}';
    }
    if (value is List) {
      return '[${value.map(_dartLiteral).join(', ')}]';
    }
    return "'$value'";
  }
}
```

- [ ] **Step 4: Export TestGenerator from barrel**

In `lib/flutter_api_client.dart`, add after `export 'src/spec/spec_mock_adapter.dart';`:

```dart
export 'src/spec/test_generator.dart';
```

- [ ] **Step 5: Run tests and verify they pass**

```bash
dart test test/test_generator_test.dart
```

Expected: All 12 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/src/spec/test_generator.dart lib/flutter_api_client.dart test/test_generator_test.dart
git commit -m "feat: add TestGenerator — generates runnable test file from ApiSpec"
```

---

## Task 2: Build-runner test scaffold

**Files:**
- Modify: `lib/src/gen/api_spec_builder.dart`
- Modify: `build.yaml`

- [ ] **Step 1: Add _ApiSpecTestBuilder to api_spec_builder.dart**

Append to `lib/src/gen/api_spec_builder.dart` (after the existing `_ApiSpecGenerator` class):

```dart
/// Emits a standalone `.test.g.dart` smoke-test scaffold.
Builder apiSpecTestBuilder(BuilderOptions options) => _ApiSpecTestBuilder();

class _ApiSpecTestBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': ['.test.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (!await buildStep.resolver.isLibrary(buildStep.inputId)) return;
    final lib = await buildStep.resolver.libraryFor(buildStep.inputId);
    const checker = TypeChecker.fromRuntime(ApiSpecEntry);
    final annotated = lib.topLevelElements
        .where((e) => checker.hasAnnotationOf(e))
        .toList();
    if (annotated.isEmpty) return;

    final varName = annotated.first.name!;
    final inputBasename = buildStep.inputId.pathSegments.last;

    final content = '''
// GENERATED CODE - DO NOT MODIFY BY HAND
// Run `dart run build_runner build` to regenerate.

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import './$inputBasename';

void main() {
  test('spec loads without error', () {
    expect($varName, isNotNull);
    expect($varName.endpoints, isNotEmpty);
  });

  group('Endpoint registration', () {
    for (final ep in $varName.endpoints) {
      test('\${ep.method} \${ep.path} is registered', () {
        expect(ep.path, startsWith('/'));
        expect(ep.method, isNotEmpty);
      });
    }
  });
}
''';

    final outputId = buildStep.inputId.changeExtension('.test.g.dart');
    await buildStep.writeAsString(outputId, content);
  }
}
```

- [ ] **Step 2: Register new builder in build.yaml**

Replace `build.yaml` contents:

```yaml
builders:
  api_spec_builder:
    import: "package:flutter_api_client/src/gen/api_spec_builder.dart"
    builder_factories: ["apiSpecBuilder"]
    build_extensions: {".dart": [".api_spec_entry.g.part"]}
    auto_apply: dependents
    build_to: cache
    applies_builders: ["source_gen|combining_builder"]

  api_spec_test_builder:
    import: "package:flutter_api_client/src/gen/api_spec_builder.dart"
    builder_factories: ["apiSpecTestBuilder"]
    build_extensions: {".dart": [".test.g.dart"]}
    auto_apply: dependents
    build_to: source
    runs_before: ["source_gen|combining_builder"]
```

- [ ] **Step 3: Run build_runner in example and verify output**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client/example
dart run build_runner build --delete-conflicting-outputs
```

Expected: `lib/my_spec.test.g.dart` is created.

- [ ] **Step 4: Verify the scaffold compiles**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client/example
dart analyze lib/my_spec.test.g.dart
```

Expected: No errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
git add lib/src/gen/api_spec_builder.dart build.yaml example/lib/my_spec.test.g.dart
git commit -m "feat: build-runner emits .test.g.dart scaffold via _ApiSpecTestBuilder"
```

---

## Task 3: CLI --only tests / --tests flag

**Files:**
- Modify: `lib/src/gen/cli_helpers.dart`
- Modify: `bin/gen.dart`
- Modify: `test/gen_cli_test.dart`

- [ ] **Step 1: Add failing tests for 'tests' in parseOnly**

In `test/gen_cli_test.dart`, inside the `group('parseOnly', ...)` block add:

```dart
test("accepts 'tests' as a valid generator", () {
  expect(parseOnly('tests'), equals(['tests']));
});

test("accepts 'tests' mixed with openapi", () {
  expect(parseOnly('openapi,tests'), containsAll(['openapi', 'tests']));
});
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
dart test test/gen_cli_test.dart
```

Expected: 2 new tests FAIL with `ArgumentError`.

- [ ] **Step 3: Add 'tests' to _validGenerators**

In `lib/src/gen/cli_helpers.dart`, change:

```dart
const _validGenerators = ['openapi', 'reference', 'backend'];
```

to:

```dart
const _validGenerators = ['openapi', 'reference', 'backend', 'tests'];
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/gen_cli_test.dart
```

Expected: all tests PASS.

- [ ] **Step 5: Add --tests flag to bin/gen.dart**

In `bin/gen.dart`, add after the `--no-yaml` flag line:

```dart
..addFlag('tests', negatable: false,
    help: 'Shorthand for --only tests; writes test/api_spec_test.dart')
```

After the `final dryRun = ...` line, add:

```dart
final testsShorthand = parsed['tests'] as bool;
if (testsShorthand) generators = ['tests'];
```

- [ ] **Step 6: Wire TestGenerator into _runnerSource**

In `bin/gen.dart`, inside `_runnerSource`, add `final genTests = generators.contains('tests');` alongside the other `genX` booleans, then inside the generated `main()` body add:

```dart
  if (\${genTests}) {
    final testDir = Directory('test');
    if (!\${dryRun}) testDir.createSync(recursive: true);
    write('test/api_spec_test.dart', TestGenerator(spec).generate()
        .replaceAll('SpecMockAdapter(spec', 'SpecMockAdapter(\$generatedSpec'));
  }
```

Also ensure the generated runner imports `TestGenerator` — it already imports `flutter_api_client` which now exports it.

- [ ] **Step 7: Smoke-test the CLI in example**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client/example
dart run flutter_api_client:gen --only tests
```

Expected: prints `✓ test/api_spec_test.dart` and exits 0.

- [ ] **Step 8: Verify generated file compiles**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client/example
dart analyze test/api_spec_test.dart
```

Expected: No errors.

- [ ] **Step 9: Commit**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
git add lib/src/gen/cli_helpers.dart bin/gen.dart test/gen_cli_test.dart
git commit -m "feat: add --only tests / --tests flag to gen CLI"
```

---

## Task 4: Docs overhaul

**Files:**
- Modify: `README.md`
- Modify: `API_SERVICES_GUIDE.md`
- Create: `TESTING.md`

- [ ] **Step 1: Add 3-step Quick Start to README**

Find the `## Why this package` heading in `README.md` and insert immediately before it:

```markdown
## Quick start — 3 steps

**1. Add the dependency**

```yaml
dependencies:
  flutter_api_client: ^2.0.0

dev_dependencies:
  build_runner: ^2.4.0
```

**2. Define your spec and generate files**

```dart
// lib/my_api.dart
import 'package:flutter_api_client/flutter_api_client.dart';
part 'my_api.g.dart';

@ApiSpecEntry()
final myApi = ApiSpec(
  title: 'My API',
  version: '1.0.0',
  baseUrl: 'https://api.example.com',
)..group('Users', (g) {
    g.endpoint('GET /users', responses: [ResponseExample.ok({'users': []})]);
  });
```

```bash
dart run build_runner build
# Generates:
#   lib/my_api.g.dart         — spec accessor
#   lib/my_api.test.g.dart    — runnable test scaffold
```

**3. Generate docs and a full test suite**

```bash
dart run flutter_api_client:gen
# Writes: docs/api/openapi.json, openapi.yaml, api-reference.md, backend-guide.md

dart run flutter_api_client:gen --only tests
# Writes: test/api_spec_test.dart  (complete runnable tests for every endpoint)

dart test --concurrency=8
```

---

```

- [ ] **Step 2: Rewrite API_SERVICES_GUIDE.md**

Replace the full contents of `API_SERVICES_GUIDE.md` with:

```markdown
# API Services Guide

> Copy this guide to any Flutter/Dart project. It shows how to define, mock, and test APIs using `flutter_api_client`.

---

## 1. Dependencies (pubspec.yaml)

```yaml
dependencies:
  flutter_api_client: ^2.0.0

dev_dependencies:
  build_runner: ^2.4.0
```

---

## 2. Project structure

```
lib/core/api/
├── my_api.dart           # @ApiSpecEntry() definition — you write this
├── my_api.g.dart         # generated — do not edit
├── my_api.test.g.dart    # generated test scaffold — do not edit
└── api_service.dart      # your service layer
```

---

## 3. Define your spec

```dart
// lib/core/api/my_api.dart
import 'package:flutter_api_client/flutter_api_client.dart';
part 'my_api.g.dart';

@ApiSpecEntry()
final myApiSpec = ApiSpec(
  title: 'My App API',
  version: '1.0.0',
  baseUrl: 'https://api.example.com/v1',
)..group('Users', (g) {
    g.endpoint(
      'GET /users',
      summary: 'List users',
      responses: [ResponseExample.ok({'users': [], 'total': 0})],
    );
    g.endpoint(
      'POST /users',
      summary: 'Create user',
      request: RequestExample(
        body: {'name': 'Alice', 'email': 'alice@example.com'},
        schema: Schema.object({
          'name': Schema.string(required: true),
          'email': Schema.string(format: 'email', required: true),
        }),
      ),
      responses: [
        ResponseExample.created({'id': 1, 'name': 'Alice'}),
        ResponseExample.error(422, {'message': 'validation error'}),
      ],
    );
  });
```

```bash
dart run build_runner build
```

---

## 4. Create your ApiClient

```dart
// lib/core/api/api_service.dart
import 'package:flutter_api_client/flutter_api_client.dart';

final apiClient = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://api.example.com/v1',
    tokenStorage: MemoryTokenStorage(accessToken: 'your-jwt-here'),
    interceptors: [
      RetryInterceptor(),
      CacheInterceptor(store: MemoryCacheStore()),
      PrettyLogger(),
    ],
  ),
);
```

---

## 5. Make requests — ApiResult\<T\>

All methods return `ApiResult<T>`, a sealed class with two subtypes: `ApiSuccess<T>` and `ApiFailure<T>`.

```dart
// Pattern A — isSuccess check
final result = await apiClient.get<Map<String, dynamic>>('users');
if (result.isSuccess) {
  final users = result.data;
} else {
  print(result.errorMessage);
}

// Pattern B — when()
final result = await apiClient.post<Map<String, dynamic>>(
  'users',
  {'name': 'Alice', 'email': 'alice@example.com'},
);
result.when(
  success: (data, statusCode, headers) => print('Created: $data'),
  failure: (error, statusCode, headers) => print('Error $statusCode: $error'),
);

// Pattern C — switch (Dart 3)
switch (result) {
  case ApiSuccess(:final data):
    print(data);
  case ApiFailure(:final errorMessage):
    print(errorMessage);
}
```

---

## 6. Testing

```bash
# Generate a full test suite from your spec:
dart run flutter_api_client:gen --only tests
# Writes: test/api_spec_test.dart

dart test --concurrency=8
```

Or use `SpecMockAdapter` directly in your own tests:

```dart
final client = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com/v1',
  adapter: SpecMockAdapter(myApiSpec),
));
final result = await client.get<Map<String, dynamic>>('users');
expect(result.isSuccess, true);
```

See [TESTING.md](TESTING.md) for a full cheat-sheet.
```

- [ ] **Step 3: Create TESTING.md**

Create `TESTING.md` at the project root:

```markdown
# Testing Cheat-Sheet

Quick reference for testing code that uses `flutter_api_client`.

---

## MockAdapter — manual stubs

Full control over every response. Use when you don't have an `ApiSpec`.

```dart
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GET /users returns list', () async {
    final adapter = MockAdapter()
      ..stub('GET', '/users', statusCode: 200, body: {'users': []});

    final client = ApiClient(ApiClientConfig.test(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
    ));

    final result = await client.get<Map<String, dynamic>>('users');
    expect(result.isSuccess, true);
    expect(result.data, contains('users'));
  });
}
```

---

## SpecMockAdapter — spec-driven mock

Automatically matches routes, validates request bodies, and returns the response examples you defined in your `ApiSpec`.

```dart
final client = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com',
  adapter: SpecMockAdapter(myApiSpec),
));

// Happy path
final res = await client.get<Map<String, dynamic>>('users');
expect(res.isSuccess, true);

// Force a specific status code
final client401 = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com',
  adapter: SpecMockAdapter(myApiSpec,
    statusOverrides: const {'GET /users': 401},
  ),
));
expect((await client401.get<dynamic>('users')).statusCode, 401);

// Schema validation — invalid body returns 422
final res3 = await client.post<dynamic>('users', {});
expect(res3.statusCode, 422);
```

---

## Generated test scaffold (.test.g.dart)

After `dart run build_runner build`, you get `lib/my_api.test.g.dart` — a minimal smoke test that confirms your spec loads and all endpoints are registered.

```bash
dart test lib/my_api.test.g.dart
```

---

## Full generated test suite

```bash
dart run flutter_api_client:gen --only tests
# Writes: test/api_spec_test.dart
```

Covers happy path, schema validation failures, auth checks, and error responses for every endpoint. Safe to customise — won't be overwritten unless you re-run the command.

---

## Running tests

```bash
# All tests, 8 workers in parallel
dart test --concurrency=8

# Single file
dart test test/api_spec_test.dart

# Filter by name
dart test --name "happy path"
```

---

## ApiResult\<T\> assertions

```dart
expect(result.isSuccess, true);
expect(result.statusCode, 200);
expect(result.data, {'users': []});
expect(result.errorMessage, contains('invalid'));
```
```

- [ ] **Step 4: Commit docs**

```bash
git add README.md API_SERVICES_GUIDE.md TESTING.md
git commit -m "docs: 3-step quick-start in README, update API_SERVICES_GUIDE to ApiResult<T>, add TESTING.md"
```

---

## Task 5: Full test run verification

- [ ] **Step 1: Run all tests in parallel**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
dart test --concurrency=8
```

Expected: All tests PASS.

- [ ] **Step 2: Build and test example**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client/example
dart run build_runner build --delete-conflicting-outputs
dart analyze
```

Expected: No errors.

- [ ] **Step 3: Smoke-test all gen CLI flags**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client/example
dart run flutter_api_client:gen
dart run flutter_api_client:gen --only tests
dart run flutter_api_client:gen --tests
dart run flutter_api_client:gen --dry-run
```

Expected: each exits 0, prints expected file list.

- [ ] **Step 4: Final fixup commit if needed**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
git add -u && git status
# Only commit if there are actual changes
git commit -m "fix: post-integration fixups" || echo "Nothing to commit"
```
