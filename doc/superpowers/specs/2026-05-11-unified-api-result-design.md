# Design: Unified `ApiResult<T>` API Surface

**Date:** 2026-05-11
**Status:** Approved
**Scope:** `flutter_api_client` v1.x — breaking change, targets pub.dev developers

---

## Problem

The package currently exposes two parallel result types:

- `CustomApiResponse<T>` — returned by `get()`, `post()`, `put()`, `patch()`, `delete()`
- `ApiResult<T>` — returned by the separate `request()` method

This forces pub.dev developers to learn two mental models, pick one, and live with the trade-offs of their choice. `CustomApiResponse` gives a simple `.isSuccess` / `.errorMessage` string but loses typed error information. `ApiResult` gives typed errors via `.when()` but has no convenience path for simple cases. Neither is complete.

---

## Goal

One result type that satisfies both usage patterns:

1. **Simple** — `result.isSuccess`, `result.data`, `result.errorMessage` for quick UI code
2. **Typed** — `result.when(success:, failure:)` + sealed `ApiException` for per-error-type handling

---

## Changes

### 1. `ApiResult<T>` — add convenience accessors

The sealed class gains three new getters. No new subclasses, no behavior change.

```dart
sealed class ApiResult<T> {
  // Existing — unchanged
  bool get isSuccess;
  bool get isFailure;
  R when<R>({required R Function(T) success, required R Function(ApiException) failure});
  ApiResult<R> map<R>(R Function(T data) transform);

  // New convenience accessors
  T? get data;              // non-null on Success, null on Failure
  ApiException? get error;  // non-null on Failure, null on Success
  String? get errorMessage; // shorthand for error?.message
  int? get statusCode;      // HTTP status on both branches where available
  Map<String, String> get headers; // response headers, empty map on Failure
}
```

`Success<T>` already has `data`, `statusCode`, `headers` — these become overrides.
`Failure<T>` already has `error`, `statusCode` — `data` returns null, `headers` returns `{}`.

### 2. HTTP methods — return `ApiResult<T>`

All five methods on `ApiClientInterface` change return type from `CustomApiResponse<T>` to `ApiResult<T>`:

```dart
Future<ApiResult<T>> get<T>(String endpoint, { ... });
Future<ApiResult<T>> post<T>(String endpoint, dynamic data, { ... });
Future<ApiResult<T>> put<T>(String endpoint, dynamic data, { ... });
Future<ApiResult<T>> patch<T>(String endpoint, dynamic data, { ... });
Future<ApiResult<T>> delete<T>(String endpoint, { ... });
```

Parameter signatures are unchanged.

### 3. Internal implementation — one path, not two

`_makeRequest()` is deleted. All five methods delegate to the existing `request()` logic (which already builds `ApiResult<T>` correctly). `request()` itself becomes private or is inlined — it was only public as a workaround for the dual-type problem.

### 4. `CustomApiResponse` — deleted

The class `CustomApiResponse<T>` in `api_response.dart` is removed entirely. The file is deleted and no longer exported from `flutter_api_client.dart`.

---

## What is NOT changed

- `ApiException` hierarchy (`NetworkError`, `TimeoutError`, `CancelError`, `HttpError`, `ParseError`, `UnknownError`) — untouched
- `GraphQLResponse` — has its own response type, unaffected
- `ApiSpec` / `SpecMockAdapter` — unaffected
- `RequestOptions`, `CancelToken`, `FormData`, interceptors, auth, adapters — all unaffected
- `ApiClientConfig` and its factory constructors — unaffected

---

## Usage examples

**Simple path:**
```dart
final result = await client.get<User>('users/me', decoder: User.fromJson);
if (result.isSuccess) {
  print(result.data!.name);
} else {
  showSnackbar(result.errorMessage!);
}
```

**Typed error handling:**
```dart
result.when(
  success: (user) => updateState(user),
  failure: (err) => switch (err) {
    HttpError(statusCode: 401) => logout(),
    HttpError(statusCode: 404) => showNotFound(),
    NetworkError()             => showOfflineBanner(),
    TimeoutError()             => showRetryPrompt(),
    _                          => showSnackbar(err.message),
  },
);
```

**Chaining:**
```dart
final nameResult = await client
    .get<User>('users/me', decoder: User.fromJson)
    .then((r) => r.map((u) => u.name));
```

---

## Files to change

| File | Change |
|------|--------|
| `lib/src/core/api_result.dart` | Add `data`, `error`, `errorMessage`, `statusCode`, `headers` getters to base class |
| `lib/src/core/api_client.dart` | Change return types; remove `_makeRequest()`; make `request()` private |
| `lib/src/core/api_response.dart` | Delete |
| `lib/flutter_api_client.dart` | Remove `api_response.dart` export |
| `test/` | Update tests to use `ApiResult<T>` instead of `CustomApiResponse` |

---

## Breaking changes summary

| Removed | Replacement |
|---------|-------------|
| `CustomApiResponse<T>` | `ApiResult<T>` |
| `CustomApiResponse.isSuccess` | `ApiResult.isSuccess` |
| `CustomApiResponse.errorMessage` | `ApiResult.errorMessage` |
| `CustomApiResponse.data` | `ApiResult.data` |
| `CustomApiResponse.statusCode` | `ApiResult.statusCode` |
| `CustomApiResponse.headers` | `ApiResult.headers` |
| `CustomApiResponse.rawBody` | Use `ResponseType.bytes` in `RequestOptions`; `result.data` will be `List<int>` |
| `client.request()` (public) | Use `client.get()` / `post()` / etc. directly |
