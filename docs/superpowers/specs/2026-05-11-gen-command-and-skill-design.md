# Design: `gen` Command, `@ApiSpecEntry` Annotation, and Claude Code Skill

**Date:** 2026-05-11
**Status:** Approved
**Scope:** `flutter_api_client` — new feature additions, no breaking changes

---

## Problem

The package has three powerful generators (`OpenApiGenerator`, `MarkdownDocGenerator`, `BackendGuideGenerator`) and a rich `ApiSpec` DSL, but:

1. Developers must manually wire up and call each generator in their own script.
2. There is no standard way for a coding agent to know how to use this package correctly.
3. There is no CLI command — the only path is writing boilerplate Dart.

---

## Goal

1. **`@ApiSpecEntry()` annotation** — marks the spec instance for discovery.
2. **`build_runner` builder** — generates a glue file so the CLI can import the spec.
3. **`dart run flutter_api_client:gen` CLI** — runs all generators, writes output, supports flags.
4. **Claude Code skill** — teaches any coding agent full package expertise.

---

## Part 1: Annotation + Builder

### New annotation

```dart
// lib/src/gen/api_spec_entry.dart
class ApiSpecEntry {
  const ApiSpecEntry();
}
```

Exported from `flutter_api_client.dart`. Developer annotates their spec:

```dart
// lib/api_spec.dart
import 'package:flutter_api_client/flutter_api_client.dart';

@ApiSpecEntry()
final mySpec = ApiSpec(
  title: 'My API',
  version: '1.0.0',
  baseUrl: 'https://api.example.com',
);
```

### Builder

```dart
// lib/src/gen/api_spec_builder.dart
```

- Implements `package:build`'s `Builder` interface
- Scans for `@ApiSpecEntry()` on top-level variables
- Generates `<filename>.g.dart` alongside the annotated file:

```dart
// GENERATED — do not edit. Run `dart run build_runner build` to regenerate.
import 'package:flutter_api_client/flutter_api_client.dart';
import 'api_spec.dart' as _spec;

ApiSpec get $generatedSpec => _spec.mySpec;
```

### `build.yaml`

```yaml
builders:
  api_spec_builder:
    import: "package:flutter_api_client/src/gen/api_spec_builder.dart"
    builder_factories: ["apiSpecBuilder"]
    build_extensions: {".dart": [".g.dart"]}
    build_to: source
```

### Developer setup

Add to `pubspec.yaml`:
```yaml
dev_dependencies:
  build_runner: ^2.4.0
  source_gen: ^1.5.0
```

Then run:
```bash
dart run build_runner build
```

---

## Part 2: CLI command (`bin/gen.dart`)

Entry point: `bin/gen.dart`. Registered as a script in `pubspec.yaml` executables.

### How the CLI loads the user's spec

The CLI cannot import the generated `$generatedSpec` at compile time (it lives in the user's project, not the package). The correct pattern is a two-step subprocess:

1. `build_runner` generates `lib/api_spec.g.dart` in the user's project — this file contains `$generatedSpec`.
2. `dart run flutter_api_client:gen` generates a temporary runner script in the user's project (`tool/.flutter_api_client_runner.dart`), then invokes it via `dart run tool/.flutter_api_client_runner.dart` as a subprocess. The runner imports `$generatedSpec`, serialises the spec to JSON on stdout, and the CLI reads that JSON to drive the generators.

The temporary runner file is deleted after use. If `build_runner` has not been run (no `*.g.dart` found containing `\$generatedSpec`), the CLI exits with a clear error before spawning the subprocess.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--output` / `-o` | `docs/api/` | Output directory |
| `--only` | all | Comma-separated subset: `openapi`, `reference`, `backend` |
| `--framework` | `none` | Backend snippets: `express`, `fastapi`, `gin` |
| `--no-json` | false | Skip `openapi.json`, only write YAML |
| `--no-yaml` | false | Skip `openapi.yaml`, only write JSON |
| `--dry-run` | false | Print paths without writing files |

### Default output structure

```
docs/api/
  openapi.json
  openapi.yaml
  api-reference.md
  backend-guide.md
```

### Console output

```
flutter_api_client gen
─────────────────────────────────────────
✓ Loaded spec: My API v1.0.0  (12 endpoints)
✓ docs/api/openapi.json        (4.2 KB)
✓ docs/api/openapi.yaml        (3.1 KB)
✓ docs/api/api-reference.md    (8.7 KB)
✓ docs/api/backend-guide.md    (11.2 KB)
─────────────────────────────────────────
Done. 4 files written.
```

### Errors

- If no `*.g.dart` with `$generatedSpec` is found: print a clear message directing the user to run `dart run build_runner build` first.
- If `--only` contains an unknown value: print valid options and exit with code 1.

### `pubspec.yaml` addition

```yaml
executables:
  gen: gen
```

---

## Part 3: Claude Code skill

**Location:** `~/.claude/plugins/user-skills/flutter-api-client/skill.md` (user-level skill, available in all projects via the Skill tool)

**Structure:** Four sections, each as a cheat sheet with working code snippets.

### Section 1 — Writing `ApiSpec`

Covers: `ApiSpec` constructor, `group()`, `endpoint()` with `'METHOD /path'` format, `Schema.*` factories (`string`, `integer`, `number`, `boolean`, `object`, `array`), `RequestExample`, `ResponseExample.*` factories (`ok`, `created`, `noContent`, `error`), `pathParams`/`queryParams`, `graphql()` section with `GraphQLSection`, `@ApiSpecEntry()` placement.

### Section 2 — Running the generator

Covers: `dart run build_runner build` (must run first), `dart run flutter_api_client:gen` with all flags, expected output paths, how to verify output, common error: missing build step.

### Section 3 — Using `ApiResult<T>`

Covers: unified result type, `result.data` / `result.errorMessage` for simple cases, `result.when()` + sealed `ApiException` switch for typed handling, `result.map()` for chaining, all five HTTP methods (`get`, `post`, `put`, `patch`, `delete`), `decoder` parameter pattern, `RequestOptions` (query params, timeout, cancel token, response type).

### Section 4 — Full package features

Covers: `ApiClientConfig` constructors, interceptors (`RetryInterceptor`, `CacheInterceptor`, `DedupInterceptor`, `PrettyLogger`, `CurlLogger`, `OfflineQueueInterceptor`), auth (`withToken`, `withStorage`, `MemoryTokenStorage`), `MockAdapter` for unit tests, `SpecMockAdapter` driven by `ApiSpec`, `GraphQLClient` with queries/mutations, `CancelToken`.

---

## Files to create

| File | Purpose |
|------|---------|
| `lib/src/gen/api_spec_entry.dart` | `@ApiSpecEntry()` annotation class |
| `lib/src/gen/api_spec_builder.dart` | `build_runner` builder implementation |
| `build.yaml` | Declares the builder to `build_runner` |
| `bin/gen.dart` | CLI entry point |
| `~/.claude/plugins/user-skills/flutter-api-client/skill.md` | Claude Code skill |

## Files to modify

| File | Change |
|------|--------|
| `pubspec.yaml` | Add `executables: {gen: gen}`, add `build` to `dependencies`, add `build_runner` + `source_gen` to `dev_dependencies` |
| `lib/flutter_api_client.dart` | Export `api_spec_entry.dart` |

---

## What is NOT changed

- `ApiSpec`, `EndpointSpec`, `Schema`, `RequestExample`, `ResponseExample` — untouched
- `BackendGuideGenerator`, `MarkdownDocGenerator`, `OpenApiGenerator` — called by the CLI, not changed
- `SpecMockAdapter`, `GraphQLClient`, interceptors — untouched
- The unified `ApiResult<T>` changes from the previous spec are independent and proceed separately

---

## Full developer workflow (end state)

```bash
# 1. Annotate your spec (once)
# lib/api_spec.dart — add @ApiSpecEntry() to your ApiSpec variable

# 2. Generate the glue file (after any spec change)
dart run build_runner build

# 3. Generate docs
dart run flutter_api_client:gen

# 4. With options
dart run flutter_api_client:gen --framework express --output docs/backend/

# 5. Dry run to preview
dart run flutter_api_client:gen --dry-run
```
