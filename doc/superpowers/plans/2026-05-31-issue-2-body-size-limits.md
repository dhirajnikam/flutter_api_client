# Issue #2 — Request and Response Body Size Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add backward-compatible request and response body byte limits to the default adapter path, with a dedicated typed error and focused verification.

**Architecture:** Keep limits opt-in via `null` defaults, resolve effective limits from `RequestOptions` over `ApiClientConfig`, and enforce them only in `DefaultHttpAdapter`. Request-size checks happen before send when length is knowable; response-size checks happen while streaming before the full body is buffered.

**Tech Stack:** Flutter, Dart, `flutter_test`, `package:http`

---

## File structure

| File | Responsibility |
|---|---|
| `lib/src/core/api_exception.dart` | Add `PayloadTooLargeError` |
| `lib/src/core/request_options.dart` | Add per-request body size overrides |
| `lib/src/core/api_client.dart` | Add config-level limits and option resolution |
| `lib/src/http/default_http_adapter.dart` | Enforce request/response byte limits |
| `README.md` | Document the new options and error |
| `test/default_http_adapter_test.dart` | Add focused adapter limit tests |
| `test/flutter_api_client_test.dart` | Cover config and request option defaults/copy behavior |

---

### Task 1: Add failing API surface and adapter tests

**Files:**
- Modify: `test/flutter_api_client_test.dart`
- Modify: `test/default_http_adapter_test.dart`
- Read: `lib/src/core/request_options.dart`
- Read: `lib/src/core/api_client.dart`
- Read: `lib/src/http/default_http_adapter.dart`

- [ ] **Step 1: Add failing config and RequestOptions tests**

Add tests under existing groups in `test/flutter_api_client_test.dart` for:

```dart
test('RequestOptions defaults body limits to null', () {
  const o = RequestOptions();
  expect(o.maxRequestBodyBytes, isNull);
  expect(o.maxResponseBodyBytes, isNull);
});

test('RequestOptions copyWith updates body limits', () {
  const o = RequestOptions();
  final n = o.copyWith(maxRequestBodyBytes: 10, maxResponseBodyBytes: 20);
  expect(n.maxRequestBodyBytes, 10);
  expect(n.maxResponseBodyBytes, 20);
});

test('ApiClientConfig.test keeps body limits null by default', () {
  final config = ApiClientConfig.test(
    baseUrl: 'https://api.example.com',
    adapter: MockAdapter(),
  );
  expect(config.maxRequestBodyBytes, isNull);
  expect(config.maxResponseBodyBytes, isNull);
});
```

- [ ] **Step 2: Add failing adapter limit tests**

Add tests to `test/default_http_adapter_test.dart` for:

1. request body over limit throws `PayloadTooLargeError`
2. response body over limit throws `PayloadTooLargeError`
3. per-request unlimited/default path still succeeds
4. shared-client path also surfaces `PayloadTooLargeError` without forcing client close semantics assertions unrelated to size limits

Use an instrumented `http.BaseClient` similar to the existing probe client; do not use live network.

- [ ] **Step 3: Run the focused failing tests**

Run:
```bash
flutter test test/flutter_api_client_test.dart test/default_http_adapter_test.dart
```

Expected: FAIL because the new fields and error type do not exist yet.

- [ ] **Step 4: Adjust only the tests until they fail for the intended reason**

If needed, fix imports/test harness shape, but do not implement production code yet.

- [ ] **Step 5: Re-run to confirm true RED state**

Run:
```bash
flutter test test/flutter_api_client_test.dart test/default_http_adapter_test.dart
```

Expected: FAIL on missing fields / missing error / missing enforcement.

- [ ] **Step 6: Commit the red tests**

```bash
git add test/flutter_api_client_test.dart test/default_http_adapter_test.dart
git commit -m "test: cover payload body size limits"
```

---

### Task 2: Add the error type and public option fields

**Files:**
- Modify: `lib/src/core/api_exception.dart`
- Modify: `lib/src/core/request_options.dart`
- Modify: `lib/src/core/api_client.dart`

- [ ] **Step 1: Add `PayloadTooLargeError` to `api_exception.dart`**

Add:

```dart
final class PayloadTooLargeError extends ApiException {
  const PayloadTooLargeError(
    super.message, {
    this.limitBytes,
    this.actualBytes,
    this.direction,
    super.cause,
    super.stackTrace,
  });

  final int? limitBytes;
  final int? actualBytes;
  final String? direction;
}
```

Place it next to the other typed API exceptions.

- [ ] **Step 2: Add limit fields to `RequestOptions`**

Extend the constructor, fields, and `copyWith()` with:

```dart
this.maxRequestBodyBytes,
this.maxResponseBodyBytes,
```

and matching final fields:

```dart
final int? maxRequestBodyBytes;
final int? maxResponseBodyBytes;
```

- [ ] **Step 3: Add limit fields to `ApiClientConfig`**

Thread `maxRequestBodyBytes` and `maxResponseBodyBytes` through:
- main constructor
- `withToken`
- `withStorage`
- `test`

and add final fields on the config object.

- [ ] **Step 4: Resolve effective request options in `ApiClient`**

Update the option-resolution path in `lib/src/core/api_client.dart` so the per-request values inherit from config when unset.

- [ ] **Step 5: Run focused tests**

Run:
```bash
flutter test test/flutter_api_client_test.dart test/default_http_adapter_test.dart
```

Expected: some tests still fail because adapter enforcement is not implemented yet, but missing-field failures are gone.

- [ ] **Step 6: Commit the API surface change**

```bash
git add lib/src/core/api_exception.dart lib/src/core/request_options.dart lib/src/core/api_client.dart
git commit -m "feat: add payload size limit configuration"
```

---

### Task 3: Implement request and response limit enforcement in DefaultHttpAdapter

**Files:**
- Modify: `lib/src/http/default_http_adapter.dart`

- [ ] **Step 1: Add private helpers for request size checks**

Implement small helpers in `default_http_adapter.dart` along the lines of:

```dart
void _checkRequestSize(http.BaseRequest request, int? maxBytes) { ... }
void _throwPayloadTooLarge({required String direction, required int limitBytes, required int actualBytes}) { ... }
```

Use `request.contentLength` when available. For `http.Request`, that should reflect encoded body length; for multipart, enforce only when the length is known.

- [ ] **Step 2: Enforce request size before `client.send()`**

Call the request-size check after building the request and before `client.send(httpRequest)`.

- [ ] **Step 3: Enforce response size while reading the stream**

Inside the response stream loop:
- increment `received`
- compare against the effective response limit
- if exceeded:
  - close the owned client when appropriate
  - throw `PayloadTooLargeError(direction: 'response', limitBytes: ..., actualBytes: received)`
- do not continue buffering after the breach

- [ ] **Step 4: Preserve existing cancellation behavior**

Ensure the existing `CancelToken` behavior remains intact and the new size-limit logic does not swallow `CancelError`.

- [ ] **Step 5: Run focused tests to GREEN**

Run:
```bash
flutter test test/flutter_api_client_test.dart test/default_http_adapter_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit the adapter enforcement change**

```bash
git add lib/src/http/default_http_adapter.dart
git commit -m "feat: enforce payload body size limits"
```

---

### Task 4: Document the new options and error

**Files:**
- Modify: `README.md`
- Optionally modify: `lib/flutter_api_client.dart`

- [ ] **Step 1: Add README documentation for body size limits**

Document:
- `ApiClientConfig.maxRequestBodyBytes`
- `ApiClientConfig.maxResponseBodyBytes`
- matching `RequestOptions` overrides
- `PayloadTooLargeError`
- `null` means unlimited
- default-adapter scope of the guarantee

Include a small usage example similar to:

```dart
final client = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://api.example.com',
    maxResponseBodyBytes: 10 * 1024 * 1024,
  ),
);
```

- [ ] **Step 2: Update any summary/error tables that should mention the new error**

If README has a typed error table, add `PayloadTooLargeError` with a clear description.

- [ ] **Step 3: Search for any stale wording about unlimited buffering**

Run:
```bash
python - <<'PY'
from pathlib import Path
text = Path('README.md').read_text()
for needle in ['PayloadTooLargeError', 'maxResponseBodyBytes', 'maxRequestBodyBytes']:
    print(needle, needle in text)
PY
```

Expected: all three print `True`.

- [ ] **Step 4: Run docs-adjacent focused tests**

Run:
```bash
flutter test test/flutter_api_client_test.dart test/default_http_adapter_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit the doc update**

```bash
git add README.md lib/flutter_api_client.dart
git commit -m "docs: document payload body size limits"
```

Only include `lib/flutter_api_client.dart` if you intentionally changed it.

---

### Task 5: Comment on issue #2 and close it after verification

**Files:**
- Modify: none
- External: GitHub issue `#2`

- [ ] **Step 1: Confirm working tree is clean and focused checks pass**

Run:
```bash
git status --short --branch
flutter test test/flutter_api_client_test.dart test/default_http_adapter_test.dart
```

Expected: clean working tree and passing focused tests.

- [ ] **Step 2: Comment on issue #2 with grounded summary**

Use `gh issue comment 2 --body ...` summarizing:
- request and response limits were added
- defaults remain unlimited (`null`)
- per-request overrides are supported
- the guarantee is implemented in `DefaultHttpAdapter`
- oversized payloads now raise `PayloadTooLargeError`

- [ ] **Step 3: Close issue #2 after full verification succeeds**

Use:
```bash
gh issue close 2 --comment "Implemented backward-compatible request/response body size limits with PayloadTooLargeError and verified the change on mainline tests."
```

- [ ] **Step 4: Leave a short updated sequencing comment on issue #1**

Use `gh issue comment 1 --body ...` to note that #2 is done and #1 is now next.

- [ ] **Step 5: Do not create a commit for issue comments**

No repo files should change in this task.

---

### Task 6: Full verification and push readiness

**Files:**
- Verify only

- [ ] **Step 1: Run the full test suite**

Run:
```bash
flutter test --concurrency=8
```

Expected: PASS.

- [ ] **Step 2: Run analyzer**

Run:
```bash
dart analyze
```

Expected: `No issues found!`

- [ ] **Step 3: Run example verification**

Run:
```bash
cd example && dart run build_runner build --delete-conflicting-outputs && dart run flutter_api_client:gen --only tests && flutter test test/api_spec_test.dart
```

Expected: PASS.

- [ ] **Step 4: Restore transient lockfile drift if introduced by verification**

Run:
```bash
git restore -- example/pubspec.lock
```

Expected: no unintended tracked diffs remain.

- [ ] **Step 5: Confirm final clean state**

Run:
```bash
git status --short --branch
```

Expected: clean branch, ready for finishing workflow.
