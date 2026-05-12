# Test Automation, DX & Docs — Design Spec

**Date:** 2026-05-12
**Status:** Approved

---

## Overview

Three independent deliverables that together make `flutter_api_client` as automated and developer-friendly as possible:

1. **Build-runner test scaffold** — `dart run build_runner build` emits `*.test.g.dart` alongside the existing `*.g.dart`.
2. **CLI full test generation** — `dart run flutter_api_client:gen --only tests` writes a complete, immediately runnable `test/api_spec_test.dart`.
3. **Docs overhaul** — README 3-step quick-start, `API_SERVICES_GUIDE.md` updated to `ApiResult<T>`, new `TESTING.md` cheat-sheet.

---

## 1. Build-runner Test Scaffold

### Goal
When a developer runs `dart run build_runner build`, they get a minimal but runnable test file next to their spec file — no extra command required.

### Output file
`<source>.test.g.dart` — a **standalone file** (not a `part of`), importable directly by the developer or by the CLI generator.

Example: `lib/my_spec.g.dart` → `lib/my_spec_test.g.dart`

### Generated content
```dart
// GENERATED CODE - DO NOT MODIFY BY HAND
// Run `dart run build_runner build` to regenerate.

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'my_spec.dart';

void main() {
  group('Users', () {
    test('GET /users — happy path', () async {
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: SpecMockAdapter(mySpec),
      ));
      final res = await client.get<Map<String, dynamic>>('users');
      expect(res.isSuccess, true);
    });
  });
}
```

### Builder registration
- Class: `_ApiSpecTestGenerator` in `lib/src/gen/builder.dart` (alongside existing `_ApiSpecGenerator`)
- `build.yaml` entry: `SharedPartBuilder` with `generate_for` matching `**/*.dart`, output extension `.test.g.dart`
- Builder only runs when `@ApiSpecEntry()` annotation is present — no output for unrelated files

### Constraints
- Standalone file — does **not** use `part of` (avoids circular part dependencies)
- Imports the parent `.dart` file directly, not the `.g.dart` file
- Uses `ApiClientConfig.test()` which already exists in the library

---

## 2. CLI Full Test Generation

### Goal
`dart run flutter_api_client:gen --only tests` writes a complete test file covering every case a developer would write by hand.

### New flag
`--only` accepts `tests` alongside `openapi`, `reference`, `backend`.
Sugar flag `--tests` is equivalent to `--only tests`.

### Output path
Default: `test/api_spec_test.dart`
Override: `dart run flutter_api_client:gen --only tests -o test/generated`

### Generated content — per endpoint

| Case | Assertion |
|------|-----------|
| Happy path | `expect(res.isSuccess, true)` |
| Schema validation failure (if `request.schema` present) | `expect(res.statusCode, 422)` |
| Auth required (if `auth == true`) | `expect(res.statusCode, 401)` via `statusOverrides` |
| Error responses (from `responses` list with `!isSuccess`) | `expect(res.statusCode, <code>)` |
| Path param routing | Uses a concrete path like `/users/1` |

### New class
`lib/src/spec/test_generator.dart` — `TestGenerator` with a single `generate()` → `String` method, mirroring `MarkdownDocGenerator` and `OpenApiGenerator`.

### CLI wiring
- `cli_helpers.dart`: add `'tests'` to `_validGenerators`
- `bin/gen.dart`: add `--tests` flag, wire `TestGenerator` into the runner template
- Default output dir for tests is `test/` not `docs/api/`

---

## 3. Docs Overhaul

### README
- Add a **3-step Quick Start** section immediately after the badges
- Keep all existing sections unchanged
- Update test badge count after new tests land

### API_SERVICES_GUIDE.md
- Replace all `CustomApiResponse` references with `ApiResult<T>`
- Update code examples to use `.isSuccess` / `.data` / `ApiResult.when()`
- Remove the manual `ResponseHandler` boilerplate

### New: TESTING.md
One-page cheat-sheet:
- `MockAdapter` — manual stub setup
- `SpecMockAdapter` — spec-driven mock
- Using the generated scaffold (`*.test.g.dart`)
- Running: `dart test --concurrency=8`
- Overriding status codes with `statusOverrides`

---

## File Changes Summary

| File | Action |
|------|--------|
| `lib/src/gen/builder.dart` | Add `_ApiSpecTestGenerator` builder class |
| `build.yaml` | Register new builder |
| `lib/src/spec/test_generator.dart` | New — `TestGenerator` class |
| `lib/src/gen/cli_helpers.dart` | Add `'tests'` to valid generators |
| `bin/gen.dart` | Add `--tests` flag, wire `TestGenerator` |
| `lib/flutter_api_client.dart` | Export `TestGenerator` |
| `README.md` | Add 3-step quick start |
| `API_SERVICES_GUIDE.md` | Replace `CustomApiResponse` → `ApiResult<T>` |
| `TESTING.md` | New cheat-sheet |
| `test/test_generator_test.dart` | New unit tests for `TestGenerator` |

---

## Testing Plan

All tests run with `dart test --concurrency=8`.

| Test file | What it covers |
|-----------|----------------|
| `test/test_generator_test.dart` | `TestGenerator.generate()` output for various spec shapes |
| `test/gen_cli_test.dart` | (extend) `parseOnly` accepts `'tests'`; `--tests` flag |
| `test/spec_test.dart` | No changes needed |

---

## Non-Goals

- No interactive prompts or wizards
- No GraphQL test gen (out of scope for this iteration)
- No watch mode changes
- No new runtime dependencies
