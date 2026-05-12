# Unified `ApiResult<T>` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dual `CustomApiResponse` / `ApiResult` surface with a single `ApiResult<T>` that covers both simple and typed error handling.

**Architecture:** Add convenience getters (`data`, `error`, `errorMessage`, `statusCode`, `headers`) to the `ApiResult<T>` sealed base class. Redirect all five HTTP methods to use the existing `request()` logic (renamed `_request()`). Delete `CustomApiResponse` and `_makeRequest()`.

**Tech Stack:** Dart 3, `package:flutter_test` for tests. No new dependencies.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/src/core/api_result.dart` | Modify | Add `data`, `error`, `errorMessage`, `statusCode`, `headers` to base class; override in `Success` and `Failure` |
| `lib/src/core/api_client.dart` | Modify | Change all five method return types; rename `request()` → `_request()`; delete `_makeRequest()` |
| `lib/src/core/api_response.dart` | Delete | No longer needed |
| `lib/flutter_api_client.dart` | Modify | Remove `api_response.dart` export |
| `test/api_result_test.dart` | Modify | Add tests for new convenience getters |
| `test/flutter_api_client_test.dart` | Modify | Remove `CustomApiResponse` tests; add `ApiResult` integration tests |
| `test/spec_test.dart` | Modify | Update `SpecMockAdapter` test that calls `client.post` and checks `res.isSuccess` |
| `test/mock_adapter_test.dart` | Modify | Update any assertions on `CustomApiResponse` fields |

---

### Task 1: Add convenience getters to `ApiResult<T>`

**Files:**
- Modify: `lib/src/core/api_result.dart`
- Modify: `test/api_result_test.dart`

- [ ] **Step 1: Write failing tests for new getters**

Add to the bottom of `test/api_result_test.dart`, inside `main()`:

```dart
  group('ApiResult convenience getters', () {
    test('data returns value on Success', () {
      const r = Success<int>(42, statusCode: 200, headers: {'x-id': '1'});
      expect(r.data, 42);
      expect(r.error, isNull);
      expect(r.errorMessage, isNull);
      expect(r.statusCode, 200);
      expect(r.headers, {'x-id': '1'});
    });

    test('data returns null on Failure', () {
      const r = Failure<int>(HttpError('not found', statusCode: 404));
      expect(r.data, isNull);
      expect(r.error, isA<HttpError>());
      expect(r.errorMessage, 'not found');
      expect(r.statusCode, 404);
      expect(r.headers, <String, String>{});
    });

    test('Failure with no statusCode returns null statusCode', () {
      const r = Failure<int>(NetworkError('offline'));
      expect(r.statusCode, isNull);
      expect(r.errorMessage, 'offline');
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/dhirajnikam/Desktop/flutter_api_client
flutter test test/api_result_test.dart
```

Expected: FAIL — `The getter 'data' isn't defined for the class 'ApiResult'`

- [ ] **Step 3: Add convenience getters to `ApiResult<T>` base class**

Replace the entire contents of `lib/src/core/api_result.dart` with:

```dart
import 'api_exception.dart';

/// Sealed result type returned by all API calls.
///
/// Simple usage:
/// ```dart
/// final result = await client.get<User>('users/me', decoder: User.fromJson);
/// if (result.isSuccess) {
///   print(result.data!.name);
/// } else {
///   showSnackbar(result.errorMessage!);
/// }
/// ```
///
/// Typed error handling:
/// ```dart
/// result.when(
///   success: (user) => updateState(user),
///   failure: (err) => switch (err) {
///     HttpError(statusCode: 401) => logout(),
///     NetworkError()             => showOfflineBanner(),
///     _                          => showSnackbar(err.message),
///   },
/// );
/// ```
sealed class ApiResult<T> {
  const ApiResult();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  /// The decoded response body. Non-null on [Success], null on [Failure].
  T? get data => switch (this) {
    Success<T>(:final data) => data,
    Failure<T>() => null,
  };

  /// The typed error. Non-null on [Failure], null on [Success].
  ApiException? get error => switch (this) {
    Success<T>() => null,
    Failure<T>(:final error) => error,
  };

  /// Human-readable error string. Shorthand for [error]?.message.
  String? get errorMessage => error?.message;

  /// HTTP status code. Present on both branches where available.
  int? get statusCode => switch (this) {
    Success<T>(:final statusCode) => statusCode,
    Failure<T>(:final statusCode) => statusCode,
  };

  /// Response headers. Empty map on [Failure].
  Map<String, String> get headers => switch (this) {
    Success<T>(:final headers) => headers,
    Failure<T>() => const {},
  };

  /// Pattern match success / failure exhaustively.
  R when<R>({
    required R Function(T data) success,
    required R Function(ApiException error) failure,
  }) => switch (this) {
    Success<T>(:final data) => success(data),
    Failure<T>(:final error) => failure(error),
  };

  /// Map the success value to another type, passing failure through unchanged.
  ApiResult<R> map<R>(R Function(T data) transform) => switch (this) {
    Success<T>(:final data, :final statusCode, :final headers) => Success<R>(
      transform(data),
      statusCode: statusCode,
      headers: headers,
    ),
    Failure<T>(:final error, :final statusCode) => Failure<R>(
      error,
      statusCode: statusCode,
    ),
  };
}

/// Successful API result carrying the decoded body.
final class Success<T> extends ApiResult<T> {
  const Success(this.data, {required this.statusCode, this.headers = const {}});

  @override
  final T data;

  @override
  final int statusCode;

  @override
  final Map<String, String> headers;
}

/// Failed API result carrying a typed [ApiException].
final class Failure<T> extends ApiResult<T> {
  const Failure(this.error, {this.statusCode});

  @override
  final ApiException error;

  @override
  final int? statusCode;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
flutter test test/api_result_test.dart
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/api_result.dart test/api_result_test.dart
git commit -m "feat: add convenience getters to ApiResult<T> sealed class"
```

---

### Task 2: Redirect HTTP methods to `_request()`, delete `_makeRequest()`

**Files:**
- Modify: `lib/src/core/api_client.dart`

- [ ] **Step 1: Change `ApiClientInterface` return types**

In `lib/src/core/api_client.dart`, replace the abstract interface block (the `abstract class ApiClientInterface { ... }`) with:

```dart
abstract class ApiClientInterface {
  Future<ApiResult<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> post<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> put<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> patch<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> delete<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });
}
```

- [ ] **Step 2: Rename `request()` to `_request()` and replace the five `@override` methods**

In `ApiClient`, rename the existing public `request()` method to `_request()` (change the method name only — keep its body identical). Then replace all five `@override` methods and the `_makeRequest()` helper with:

```dart
  @override
  Future<ApiResult<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _request<T>('GET', endpoint,
        includeToken: includeToken, options: options, decoder: decoder);

  @override
  Future<ApiResult<T>> post<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _request<T>('POST', endpoint,
        data: data, includeToken: includeToken, isMultipart: isMultipart,
        options: options, decoder: decoder);

  @override
  Future<ApiResult<T>> put<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _request<T>('PUT', endpoint,
        data: data, includeToken: includeToken, isMultipart: isMultipart,
        options: options, decoder: decoder);

  @override
  Future<ApiResult<T>> patch<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _request<T>('PATCH', endpoint,
        data: data, includeToken: includeToken, isMultipart: isMultipart,
        options: options, decoder: decoder);

  @override
  Future<ApiResult<T>> delete<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _request<T>('DELETE', endpoint,
        includeToken: includeToken, options: options, decoder: decoder);
```

- [ ] **Step 3: Remove the `api_response.dart` import from `api_client.dart`**

Delete this line near the top of `api_client.dart`:
```dart
import 'api_response.dart';
```

- [ ] **Step 4: Run analysis**

```bash
dart analyze lib/src/core/api_client.dart
```

Expected: No issues.

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/api_client.dart
git commit -m "refactor: redirect HTTP methods to _request(), remove _makeRequest()"
```

---

### Task 3: Delete `CustomApiResponse` and update barrel export

**Files:**
- Delete: `lib/src/core/api_response.dart`
- Modify: `lib/flutter_api_client.dart`

- [ ] **Step 1: Remove the export line from `lib/flutter_api_client.dart`**

Delete this line:
```dart
export 'src/core/api_response.dart';
```

- [ ] **Step 2: Delete the file and stage the deletion**

```bash
git rm lib/src/core/api_response.dart
```

- [ ] **Step 3: Run analysis across the full library**

```bash
dart analyze lib/
```

Expected: No issues. If any file still references `CustomApiResponse` or `api_response.dart`, remove that reference now.

- [ ] **Step 4: Commit**

```bash
git add lib/flutter_api_client.dart
git commit -m "feat!: remove CustomApiResponse — all methods now return ApiResult<T>"
```

---

### Task 4: Update tests

**Files:**
- Modify: `test/flutter_api_client_test.dart`
- Modify: `test/spec_test.dart`
- Modify: `test/mock_adapter_test.dart`

- [ ] **Step 1: Replace `CustomApiResponse` group in `flutter_api_client_test.dart`**

Remove the entire `group('CustomApiResponse', ...)` block and replace with:

```dart
  group('ApiClient HTTP methods return ApiResult', () {
    late ApiClient client;

    setUp(() {
      final mock = MockAdapter();
      mock.register('GET', '/ping', (req) async => AdapterResponse(
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyBytes: Uint8List.fromList(utf8.encode('{"ok":true}')),
      ));
      mock.register('GET', '/fail', (req) async => AdapterResponse(
        statusCode: 404,
        headers: const {'content-type': 'application/json'},
        bodyBytes: Uint8List.fromList(utf8.encode('{"message":"not found"}')),
      ));
      client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://example.com',
        adapter: mock,
      ));
    });

    test('success result has data and isSuccess true', () async {
      final result = await client.get<Map<String, dynamic>>('ping');
      expect(result.isSuccess, true);
      expect(result.data, {'ok': true});
      expect(result.errorMessage, isNull);
      expect(result.statusCode, 200);
    });

    test('failure result has errorMessage and isFailure true', () async {
      final result = await client.get<Map<String, dynamic>>('fail');
      expect(result.isFailure, true);
      expect(result.data, isNull);
      expect(result.errorMessage, isNotNull);
      expect(result.statusCode, 404);
    });

    test('when() dispatches to correct branch', () async {
      final result = await client.get<Map<String, dynamic>>('ping');
      final out = result.when(
        success: (d) => 'ok',
        failure: (e) => 'fail',
      );
      expect(out, 'ok');
    });
  });
```

Add missing imports at top of file if not present:
```dart
import 'dart:convert';
import 'dart:typed_data';
```

- [ ] **Step 2: Check `spec_test.dart` for `CustomApiResponse` references**

```bash
grep -n "CustomApiResponse" test/spec_test.dart
```

If any found: `CustomApiResponse<T>` → `ApiResult<T>`, `.isSuccess` / `.data` / `.errorMessage` map directly — no rename needed.

- [ ] **Step 3: Check `mock_adapter_test.dart` for `CustomApiResponse` references**

```bash
grep -n "CustomApiResponse" test/mock_adapter_test.dart
```

Apply the same rename: `CustomApiResponse<T>` → `ApiResult<T>`.

- [ ] **Step 4: Run full test suite**

```bash
flutter test
```

Expected: All tests PASS. If any fail, search for remaining references:

```bash
grep -rn "CustomApiResponse" test/ lib/
```

- [ ] **Step 5: Commit**

```bash
git add test/
git commit -m "test: migrate all tests from CustomApiResponse to ApiResult<T>"
```

---

### Task 5: Final verification and version bump

- [ ] **Step 1: Run full analysis and tests**

```bash
dart analyze && flutter test
```

Expected: 0 analysis issues, all tests PASS.

- [ ] **Step 2: Confirm `CustomApiResponse` is completely gone**

```bash
grep -rn "CustomApiResponse" lib/ test/
```

Expected: no output.

- [ ] **Step 3: Bump version in `pubspec.yaml`**

Change:
```yaml
version: 1.0.0
```
To:
```yaml
version: 2.0.0
```

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml
git commit -m "chore: bump to v2.0.0 — unified ApiResult<T> API surface"
```
