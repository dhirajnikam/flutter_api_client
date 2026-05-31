# Design: Issue #1 — Persistent Offline Queue Store

**Date:** 2026-05-31
**Status:** Approved
**Scope:** `flutter_api_client` v1.x — add one bundled persistent `OfflineQueueStore` implementation without introducing Flutter-only runtime dependencies

---

## Problem

The package ships `OfflineQueueInterceptor` and the `OfflineQueueStore` abstraction, but the only built-in store is `InMemoryOfflineQueueStore`.

That means queued offline writes are lost on process death or app restart unless every consumer implements their own persistence backend.

This weakens the practical value of the offline queue feature.

---

## Goal

Ship one bundled persistent queue backend that works with the existing `OfflineQueueStore` interface and preserves queued requests across restarts.

The implementation must:

1. stay backward-compatible with the current interceptor API
2. avoid forcing Flutter-only platform dependencies into the package
3. be deterministic and testable
4. document the persistence contract clearly

---

## Non-Goals

- No redesign of `OfflineQueueInterceptor`
- No automatic replay engine in this change
- No migration of existing custom stores
- No Flutter-specific helper like `Hive.initFlutter()` in the package itself
- No SQLite/shared_preferences dependency in this change

---

## Approach

Add `HiveOfflineQueueStore` backed by a user-supplied `Box<String>` from `package:hive`.

Why this approach:

- `hive` is pure Dart and cross-platform
- the package stays usable outside Flutter
- users control Hive initialization and box opening according to their runtime
- the store implementation remains small and boring

Storage format:

- each queued request is stored as a JSON string keyed by `QueuedRequest.id`
- `drain()` reconstructs requests with `QueuedRequest.fromJson(...)`, sorts by `createdAt`, clears the box, and returns the drained items

Required model enhancement:

- add `QueuedRequest.fromJson(Map<String, Object?> json)`

---

## Public API changes

### `QueuedRequest`

Add:

```dart
factory QueuedRequest.fromJson(Map<String, Object?> json)
```

This complements the existing `toJson()` and makes persistence round-trippable.

### New built-in store

Add:

```dart
class HiveOfflineQueueStore implements OfflineQueueStore {
  HiveOfflineQueueStore(this.box);

  final Box<String> box;
}
```

Behavior:
- `enqueue()` writes a JSON string by request id
- `drain()` reads all values, decodes them, sorts by `createdAt`, clears the box, returns the decoded list
- `remove()` deletes by id
- `length` returns `box.length`

---

## Dependency choice

Add a normal package dependency on `hive`.

Do not add `hive_flutter`.

Reason:
- initialization strategy is app-specific
- the package should not force Flutter-only runtime APIs

User setup remains explicit:

```dart
final box = await Hive.openBox<String>('offline_queue');
final store = HiveOfflineQueueStore(box);
```

---

## Files to change

| File | Change |
|---|---|
| `pubspec.yaml` | add `hive` dependency |
| `lib/src/interceptors/offline/offline_queue.dart` | add `QueuedRequest.fromJson` and `HiveOfflineQueueStore` |
| `lib/flutter_api_client.dart` | export remains covered via existing offline export; package-level docs may mention persistent store |
| `README.md` | document `HiveOfflineQueueStore` as the built-in persistent recommendation |
| `test/offline_queue_test.dart` | add persistence round-trip and Hive-backed store tests |

---

## Test strategy

Required coverage:

1. `QueuedRequest.fromJson` round-trips the output of `toJson()`
2. `HiveOfflineQueueStore.enqueue()` persists an item and `length` reflects it
3. `HiveOfflineQueueStore.drain()` returns items in deterministic order and clears the box
4. `HiveOfflineQueueStore.remove()` deletes by id
5. reopening the same Hive box preserves queued items across store instances

Tests should use temporary directories and real Hive boxes, not mocks.

---

## Risks and mitigations

### Risk: body payload is not JSON-serializable

Mitigation:
- document that persistent queue bodies must remain JSON-compatible, matching the existing `QueuedRequest.toJson()` contract
- do not silently coerce unsupported object graphs

### Risk: ordering differs by backend internals

Mitigation:
- sort drained requests by `createdAt` before returning

### Risk: package picks an overly opinionated backend

Mitigation:
- keep `OfflineQueueStore` unchanged
- `HiveOfflineQueueStore` is additive, not replacing custom backends

---

## Acceptance criteria

- The package ships a built-in persistent `OfflineQueueStore` implementation.
- Existing `OfflineQueueInterceptor` integration remains unchanged.
- `QueuedRequest` supports JSON round-trip via `fromJson`.
- README documents `HiveOfflineQueueStore` as the built-in persistent option.
- Focused and full verification pass.
