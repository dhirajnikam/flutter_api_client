# Issue #1 — Persistent Offline Queue Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in persistent offline queue store using Hive, while preserving the existing `OfflineQueueStore` and interceptor contracts.

**Architecture:** Extend the existing offline queue model with `QueuedRequest.fromJson`, then add `HiveOfflineQueueStore` backed by a user-supplied `Box<String>`. Keep the store additive and backend-neutral from the interceptor’s perspective, and verify persistence behavior with real Hive boxes in temp directories.

**Tech Stack:** Flutter, Dart, `flutter_test`, `hive`

---

## File structure

| File | Responsibility |
|---|---|
| `pubspec.yaml` | Add the `hive` dependency |
| `lib/src/interceptors/offline/offline_queue.dart` | Add `QueuedRequest.fromJson` and `HiveOfflineQueueStore` |
| `README.md` | Document the built-in persistent store |
| `test/offline_queue_test.dart` | Add round-trip and persistence tests |

---

### Task 1: Add failing persistence tests

**Files:**
- Modify: `test/offline_queue_test.dart`
- Read: `lib/src/interceptors/offline/offline_queue.dart`

- [ ] **Step 1: Add imports for temp-dir + Hive-backed tests**

Add the imports needed for:
- `dart:io`
- `package:hive/hive.dart`

- [ ] **Step 2: Add a failing `QueuedRequest.fromJson` round-trip test**

Add a test like:

```dart
test('QueuedRequest.fromJson round-trips toJson output', () {
  final req = QueuedRequest(
    id: '42',
    method: 'PATCH',
    endpoint: '/thing',
    headers: const {'x-foo': 'bar'},
    body: {'key': 'val'},
    createdAt: DateTime(2024, 1, 15),
  );

  final decoded = QueuedRequest.fromJson(req.toJson());
  expect(decoded.id, req.id);
  expect(decoded.method, req.method);
  expect(decoded.endpoint, req.endpoint);
  expect(decoded.headers, req.headers);
  expect(decoded.body, req.body);
  expect(decoded.createdAt, req.createdAt);
});
```

- [ ] **Step 3: Add failing `HiveOfflineQueueStore` tests**

Add tests for:
- enqueue + length
- drain clears box and preserves order
- remove deletes by id
- persistence across box reopen

Use real Hive boxes in a temp directory and close them in teardown.

- [ ] **Step 4: Run the focused offline queue tests to verify RED**

Run:
```bash
flutter test test/offline_queue_test.dart
```

Expected: FAIL due to missing `QueuedRequest.fromJson`, missing `HiveOfflineQueueStore`, and missing `hive` dependency.

- [ ] **Step 5: Commit the red tests**

```bash
git add test/offline_queue_test.dart
git commit -m "test: cover persistent offline queue store"
```

---

### Task 2: Add dependency and implement the persistent store

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/src/interceptors/offline/offline_queue.dart`

- [ ] **Step 1: Add `hive` dependency**

Add a normal package dependency in `pubspec.yaml`.

- [ ] **Step 2: Add `QueuedRequest.fromJson`**

Implement a factory that reconstructs:
- `id`
- `method`
- `endpoint`
- `headers`
- `body`
- `createdAt`

using the existing `toJson()` shape.

- [ ] **Step 3: Add `HiveOfflineQueueStore`**

Implement:

```dart
class HiveOfflineQueueStore implements OfflineQueueStore {
  HiveOfflineQueueStore(this.box);

  final Box<String> box;

  @override
  Future<void> enqueue(QueuedRequest request) async { ... }

  @override
  Future<List<QueuedRequest>> drain() async { ... }

  @override
  Future<void> remove(String id) async { ... }

  @override
  Future<int> get length async => box.length;
}
```

Store JSON strings by request id. In `drain()`, decode all entries, sort by `createdAt`, clear the box, and return the decoded requests.

- [ ] **Step 4: Run focused offline queue tests to GREEN**

Run:
```bash
flutter test test/offline_queue_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit the implementation**

```bash
git add pubspec.yaml lib/src/interceptors/offline/offline_queue.dart test/offline_queue_test.dart
git commit -m "feat: add hive offline queue store"
```

---

### Task 3: Document the built-in persistent store and close the issue

**Files:**
- Modify: `README.md`
- External: GitHub issue `#1`

- [ ] **Step 1: Update the offline queue README section**

Replace the generic “implement your own persistent store” guidance with a built-in `HiveOfflineQueueStore` example and note that users open the box themselves.

- [ ] **Step 2: Run focused verification**

Run:
```bash
flutter test test/offline_queue_test.dart
```

Expected: PASS.

- [ ] **Step 3: Commit the README update**

```bash
git add README.md
git commit -m "docs: document hive offline queue store"
```

- [ ] **Step 4: Comment on and close issue #1 after full verification succeeds**

Use:
```bash
gh issue comment 1 --body "Implemented a built-in persistent HiveOfflineQueueStore backed by a user-supplied Box<String>, plus QueuedRequest JSON round-trip support and README guidance."

gh issue close 1 --comment "Implemented a built-in persistent HiveOfflineQueueStore and verified it on the mainline test suite."
```

---

### Task 4: Full verification and branch completion

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

- [ ] **Step 4: Restore transient lockfile drift if introduced**

Run:
```bash
git restore -- example/pubspec.lock
```

- [ ] **Step 5: Confirm final clean state**

Run:
```bash
git status --short --branch
```

Expected: clean branch, ready for finishing workflow.
