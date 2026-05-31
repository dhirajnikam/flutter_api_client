# Issue #3 — CancelToken Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CancelToken semantics accurate and provable by clarifying docs, adding transport-behavior tests, and posting grounded GitHub issue comments.

**Architecture:** Keep the existing `package:http` transport and current owned-vs-shared client behavior. Tighten only the documented contract, add regression tests around observable cancellation semantics, and then comment on the GitHub issues with the verified behavior and sequencing.

**Tech Stack:** Flutter, Dart, `flutter_test`, `package:http`, GitHub issue comments via `gh`

---

## File structure

| File | Responsibility |
|---|---|
| `lib/src/core/cancel_token.dart` | Public API doc comments for cancellation semantics |
| `lib/src/http/default_http_adapter.dart` | Adapter doc comments explaining owned-client vs shared-client cancellation |
| `README.md` | User-facing CancelToken docs and summary table wording |
| `test/default_http_adapter_test.dart` | New focused transport cancellation behavior tests |
| `test/mock_adapter_test.dart` | Keep existing high-level cancel behavior tests if still relevant |

---

### Task 1: Add failing transport-semantics tests

**Files:**
- Create: `test/default_http_adapter_test.dart`
- Read: `lib/src/http/default_http_adapter.dart`
- Read: `lib/src/core/cancel_token.dart`

- [ ] **Step 1: Write the failing test file**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('DefaultHttpAdapter cancellation semantics', () {
    test('owned per-request client cancellation surfaces CancelError', () async {
      final adapter = DefaultHttpAdapter();
      final token = CancelToken();

      final future = adapter.send(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/slow'),
          headers: const {'Accept': 'application/json'},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        ),
      );

      scheduleMicrotask(() => token.cancel('stop'));

      await expectLater(future, throwsA(isA<CancelError>()));
    });

    test('shared client mode does not close the injected client', () async {
      final client = _SpyClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode('{"ok":true}'),
          ]),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final adapter = DefaultHttpAdapter(client: client);
      final token = CancelToken();

      final future = adapter.send(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/shared'),
          headers: const {'Accept': 'application/json'},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        ),
      );

      scheduleMicrotask(() => token.cancel('stop'));

      await expectLater(future, throwsA(isA<CancelError>()));
      expect(client.closeCalls, 0);
    });
  });
}

class _SpyClient extends http.BaseClient {
  _SpyClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _handler;
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _handler(request);

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}
```

- [ ] **Step 2: Run the new test file to verify failure**

Run:
```bash
flutter test test/default_http_adapter_test.dart
```

Expected: FAIL because the new file either needs import fixes, timing fixes, or reveals current undocumented behavior gaps.

- [ ] **Step 3: Tighten the test so it fails for the right reason**

If the failure is just test harness shape, adjust only the test until it fails on the intended semantics rather than syntax or import errors.

- [ ] **Step 4: Re-run the test to confirm true RED state**

Run:
```bash
flutter test test/default_http_adapter_test.dart
```

Expected: FAIL on one or more cancellation semantics assertions.

- [ ] **Step 5: Commit the red test**

```bash
git add test/default_http_adapter_test.dart
git commit -m "test: cover cancel token transport semantics"
```

---

### Task 2: Implement minimal code/doc changes for issue #3

**Files:**
- Modify: `lib/src/core/cancel_token.dart`
- Modify: `lib/src/http/default_http_adapter.dart`

- [ ] **Step 1: Update `CancelToken` API docs to describe real guarantees**

Replace the class-level doc block in `lib/src/core/cancel_token.dart` with wording equivalent to:

```dart
/// Cancels one or more in-flight requests from the package API perspective.
///
/// A single token can be passed to many requests. Calling [cancel] causes those
/// requests to complete with [CancelError] without disturbing unrelated ones.
///
/// Transport-level interruption depends on the active adapter. The default
/// [DefaultHttpAdapter] attempts to interrupt owned per-request `package:http`
/// clients, but shared injected clients are not closed by one request cancel.
```

- [ ] **Step 2: Update `DefaultHttpAdapter` docs to explain owned vs shared client cancellation**

Adjust the adapter header comment in `lib/src/http/default_http_adapter.dart` to say, in code, that:

```dart
/// Default adapter built on `package:http`.
///
/// By default each request gets a private [http.Client], so cancelling a
/// request can close that owned client without affecting unrelated requests.
/// If you inject a shared [client], cancellation still surfaces as
/// [CancelError] to the caller, but this adapter will not close the shared
/// client on behalf of one request.
```

- [ ] **Step 3: Make the smallest implementation change only if tests proved one is needed**

If Task 1 showed a real code bug, implement the smallest production fix. If the current runtime behavior is already correct, do not change logic — keep this task limited to doc accuracy.

- [ ] **Step 4: Run the focused test to verify GREEN**

Run:
```bash
flutter test test/default_http_adapter_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit the minimal implementation/docs change**

```bash
git add lib/src/core/cancel_token.dart lib/src/http/default_http_adapter.dart test/default_http_adapter_test.dart
git commit -m "docs: clarify cancel token transport semantics"
```

---

### Task 3: Align README wording and tables

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update CancelToken prose**

Change the CancelToken section so the sentence currently saying `cancel() aborts every associated request` becomes wording equivalent to:

```md
A single `CancelToken` can be bound to multiple requests. `cancel()` causes
those requests to complete with `CancelError`. With the default
`DefaultHttpAdapter`, request-owned `package:http` clients are also closed on
cancel; shared injected clients are not.
```

- [ ] **Step 2: Update summary-table wording**

Replace unconditional “abort” wording in the README tables with “cancel one or more in-flight requests” or equivalent qualified wording.

- [ ] **Step 3: Search for remaining stale abort claims**

Run:
```bash
python - <<'PY'
from pathlib import Path
for path in [Path('README.md')]:
    text = path.read_text()
    for needle in ['aborts', 'Abort one or more in-flight requests']:
        if needle in text:
            print(path, needle)
PY
```

Expected: only intentional, updated wording remains.

- [ ] **Step 4: Run focused verification on docs-adjacent tests**

Run:
```bash
flutter test test/default_http_adapter_test.dart test/flutter_api_client_test.dart test/mock_adapter_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit the README update**

```bash
git add README.md
git commit -m "docs: align cancel token README semantics"
```

---

### Task 4: Comment on GitHub issues with verified status

**Files:**
- Modify: none
- External: GitHub issues `#3`, `#2`, `#1`

- [ ] **Step 1: Inspect final local verification state**

Run:
```bash
git status --short --branch
flutter test test/default_http_adapter_test.dart test/flutter_api_client_test.dart test/mock_adapter_test.dart
```

Expected: clean working tree and passing focused tests.

- [ ] **Step 2: Comment on issue #3 with grounded status**

Run a command equivalent to:

```bash
gh issue comment 3 --body "Verified current CancelToken behavior and updated docs/tests. The default DefaultHttpAdapter already attempts transport interruption for request-owned package:http clients by closing that private client on cancel. Shared injected clients are intentionally not closed by one request cancellation, so that mode is logical cancellation rather than guaranteed transport abort. I updated the package docs/tests to make this distinction explicit. Stronger platform-specific abort semantics would need an adapter-level redesign rather than a doc-only promise."
```

- [ ] **Step 3: Leave triage comment on issue #2**

```bash
gh issue comment 2 --body "Triage update: I am handling issue #3 first because it is a smaller correctness/documentation slice. Issue #2 is next in queue after that. The planned direction is configurable request/response body limits with tests around observable transport failure semantics and backward-compatible defaults."
```

- [ ] **Step 4: Leave triage comment on issue #1**

```bash
gh issue comment 1 --body "Triage update: issue #1 is queued after #3 and #2. It is a larger product/API choice because we need to decide which persistent backend can be shipped without overcommitting consumers. I plan to handle the cancellation/docs slice first, then payload limits, then come back to a bundled persistent offline queue store design."
```

- [ ] **Step 5: Commit only if any tracked file changed during this task**

If no files changed, skip commit. If issue-comment support requires a local note file, commit only that intentional artifact.

---

### Task 5: Full verification

**Files:**
- Verify: repository state only

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

- [ ] **Step 3: Run example verification if any generated/docs wording touched generated guidance**

Run:
```bash
cd example && dart run build_runner build --delete-conflicting-outputs && dart run flutter_api_client:gen --only tests && flutter test test/api_spec_test.dart
```

Expected: PASS.

- [ ] **Step 4: Commit any remaining tracked changes**

```bash
git add lib/src/core/cancel_token.dart lib/src/http/default_http_adapter.dart README.md test/default_http_adapter_test.dart
git commit -m "fix: document and verify cancel token semantics"
```

Use only if there are remaining uncommitted tracked changes after earlier commits.

- [ ] **Step 5: Push the branch**

```bash
git push origin main
```
