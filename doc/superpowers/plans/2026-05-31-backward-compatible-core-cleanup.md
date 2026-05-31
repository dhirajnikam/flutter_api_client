# Backward-Compatible Core Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the documented package contract, tighten HTTP parse error behavior, and simplify `ApiClient` internals without breaking consumers.

**Architecture:** Keep the public `ApiClient` surface unchanged while extracting small private helpers inside `lib/src/core/api_client.dart` for request normalization, payload building, and response decoding. Tighten `ResponseType.json` handling so malformed successful payloads return `ParseError`, while non-2xx responses continue returning `HttpError`.

**Tech Stack:** Dart 3, `package:flutter_test`, existing `MockAdapter` test infrastructure. No new dependencies.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/src/core/api_client.dart` | Modify | Extract private helpers and classify successful JSON parse failures as `ParseError` |
| `test/api_result_test.dart` | Modify | Add focused regression tests for malformed JSON/text payloads and empty-body success |
| `README.md` | Modify | Remove stale `CustomApiResponse` / `client.request()` docs and align examples with `ApiResult<T>` |
| `ARCHITECTURE.md` | Modify | Align architecture narrative with current result type and parse behavior |

---

### Task 1: Lock in parse semantics with failing tests

**Files:**
- Modify: `test/api_result_test.dart`
- Verify against: `lib/src/core/api_client.dart`

- [ ] **Step 1: Add failing regression tests for successful parse failures and empty-body success**

Append these tests inside `group('ApiClient HTTP verb typed path', () { ... })` in `test/api_result_test.dart`:

```dart
    test('returns Failure with ParseError on malformed JSON success body', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/broken-json$'), (_) async => AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              bodyBytes: Uint8List.fromList(utf8.encode('{bad json')),
            ));
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://example.com',
        adapter: mock,
      ));

      final result = await client.get<dynamic>('broken-json');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<ParseError>());
      expect(error.message, contains('Failed to parse JSON response'));
    });

    test('returns Failure with ParseError on text body for JSON response', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/html$'), (_) async => AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'text/html'},
              bodyBytes: Uint8List.fromList(
                utf8.encode('<html><body>oops</body></html>'),
              ),
            ));
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://example.com',
        adapter: mock,
      ));

      final result = await client.get<dynamic>('html');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<ParseError>());
      expect(error.message, contains('Expected JSON response body'));
    });

    test('returns Success with null data on empty successful JSON body', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/no-content$'), (_) async => AdapterResponse(
              statusCode: 204,
              headers: const {},
              bodyBytes: Uint8List(0),
            ));
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://example.com',
        adapter: mock,
      ));

      final result = await client.get<dynamic>('no-content');

      expect(result.isSuccess, true);
      expect(result.data, isNull);
      expect(result.statusCode, 204);
    });

    test('keeps non-2xx malformed payloads as HttpError', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/server-error$'), (_) async => AdapterResponse(
              statusCode: 500,
              headers: const {'content-type': 'application/json'},
              bodyBytes: Uint8List.fromList(utf8.encode('{bad json')),
            ));
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://example.com',
        adapter: mock,
      ));

      final result = await client.get<dynamic>('server-error');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<HttpError>());
      expect((error as HttpError).statusCode, 500);
    });
```

Also add the required imports at the top of the file:

```dart
import 'dart:convert';
import 'dart:typed_data';
```

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
flutter test test/api_result_test.dart
```

Expected: FAIL because `ApiClient` currently returns `UnknownError` or nullable success semantics instead of `ParseError` for the new cases.

- [ ] **Step 3: Commit the failing test**

```bash
git add test/api_result_test.dart
git commit -m "test: add api client parse regression coverage"
```

---

### Task 2: Refactor `ApiClient` and implement the parse fix

**Files:**
- Modify: `lib/src/core/api_client.dart`
- Verify with: `test/api_result_test.dart`

- [ ] **Step 1: Extract small private helpers and tighten parse behavior**

Update `lib/src/core/api_client.dart` with these targeted changes:

1. Keep all public method signatures unchanged.
2. Replace inline request normalization in `_send()` with a private helper:

```dart
  RequestOptions _resolveOptions(
    RequestOptions? options,
    bool includeToken,
  ) {
    final effectiveIncludeToken = options?.includeToken ?? includeToken;
    final effectiveTimeout = options?.timeout ?? _config.connectTimeout;
    final effectiveBaseUrl = options?.baseUrlOverride ?? _config.baseUrl;
    return (options ?? const RequestOptions()).copyWith(
      includeToken: effectiveIncludeToken,
      timeout: effectiveTimeout,
      baseUrlOverride: effectiveBaseUrl,
    );
  }
```

3. Replace inline header construction with:

```dart
  Map<String, String> _buildHeaders(
    RequestOptions options, {
    required bool isMultipart,
  }) =>
      <String, String>{
        'Accept': 'application/json',
        'Accept-Language': 'en',
        if (!isMultipart) 'Content-Type': 'application/json',
        ..._config.extraHeaders,
        ...options.extraHeaders,
        ...?options.headers,
      };
```

4. Replace inline multipart/body preparation with:

```dart
  ({FormData? formData, Object? body}) _buildPayload(
    dynamic data, {
    required bool isMultipart,
  }) {
    if (isMultipart) {
      if (data is FormData) {
        return (formData: data, body: null);
      }
      if (data is Map<String, dynamic>) {
        return (formData: FormData.fromMap(data), body: null);
      }
      return (formData: null, body: null);
    }
    if (data == null) {
      return (formData: null, body: null);
    }
    return (formData: null, body: encodeBody(data));
  }
```

5. Split `_decode<T>()` into success/error aware helpers. The success path must throw `ParseError` for malformed JSON or HTML/text bodies and allow empty bodies:

```dart
  T _decodeSuccessBody<T>(
    AdapterResponse res,
    ResponseType type,
    T Function(Object json)? decoder,
  ) {
    switch (type) {
      case ResponseType.bytes:
        return res.bodyBytes as T;
      case ResponseType.plainText:
        return utf8.decode(res.bodyBytes) as T;
      case ResponseType.stream:
        return res.bodyBytes as T;
      case ResponseType.json:
        final parsed = _decodeJsonSuccessBody(res, decoder);
        return parsed as T;
    }
  }

  Object? _decodeJsonSuccessBody<T>(
    AdapterResponse res,
    T Function(Object json)? decoder,
  ) {
    if (res.bodyBytes.isEmpty) return null;
    final raw = utf8.decode(res.bodyBytes);
    if (raw.trim().isEmpty) return null;
    if (_responseHandler.isHtmlOrTextResponse(raw)) {
      throw const ParseError('Expected JSON response body but received text/html.');
    }
    final parsed = _tryParseJson(raw);
    if (decoder != null && parsed != null) {
      return decoder(parsed as Object);
    }
    return parsed;
  }

  Object? _decodeErrorBody(
    AdapterResponse res,
    ResponseType type,
  ) {
    switch (type) {
      case ResponseType.bytes:
        return res.bodyBytes;
      case ResponseType.plainText:
        return utf8.decode(res.bodyBytes);
      case ResponseType.stream:
        return res.bodyBytes;
      case ResponseType.json:
        if (res.bodyBytes.isEmpty) return null;
        final raw = utf8.decode(res.bodyBytes);
        if (raw.trim().isEmpty) return null;
        if (_responseHandler.isHtmlOrTextResponse(raw)) return null;
        return _tryParseJson(raw, throwOnFailure: false);
    }
  }

  Object? _tryParseJson(String raw, {bool throwOnFailure = true}) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (e, st) {
      if (!throwOnFailure) return null;
      throw ParseError(
        'Failed to parse JSON response.',
        cause: e,
        stackTrace: st,
      );
    }
  }
```

6. Update `_request<T>()` to use `_decodeSuccessBody()` for 2xx and `_decodeErrorBody()` for non-2xx.
7. Update `_send()` and `_transport()` to use `_resolveOptions()`, `_buildHeaders()`, and `_buildPayload()`.

- [ ] **Step 2: Run the focused regression test to verify GREEN**

Run:

```bash
flutter test test/api_result_test.dart
```

Expected: PASS.

- [ ] **Step 3: Commit the implementation**

```bash
git add lib/src/core/api_client.dart test/api_result_test.dart
git commit -m "fix: classify successful parse failures as ParseError"
```

---

### Task 3: Correct docs and architecture narrative

**Files:**
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Update stale API documentation in `README.md`**

Make these corrections:

1. Remove or rewrite all references to `CustomApiResponse<T>`.
2. Remove or rewrite all references to `client.request()` as a public consumer API.
3. Ensure the “Making requests”, “Error handling”, and API reference sections consistently describe `ApiResult<T>` from the HTTP verb methods.
4. Update examples so they only use supported public calls such as `client.get<T>()`, `client.post<T>()`, and `result.when(...)`.
5. Update any migration/test-suite tables that still mention `CustomApiResponse`.

- [ ] **Step 2: Update stale architecture narrative in `ARCHITECTURE.md`**

Make these corrections:

1. Replace the “CustomApiResponse / ApiResult” dual-result description with the current `ApiResult<T>` contract.
2. Update the `ApiClient` section so its key methods reflect the actual code.
3. Document that malformed successful JSON payloads surface as `ParseError`, while non-2xx responses remain `HttpError`.
4. Keep the document focused on existing architecture; do not introduce future-state abstractions.

- [ ] **Step 3: Run a targeted stale-reference check**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
for path in [Path('README.md'), Path('ARCHITECTURE.md')]:
    text = path.read_text()
    for needle in ['CustomApiResponse', 'client.request()']:
        if needle in text:
            print(f'{path}: still contains {needle}')
PY
```

Expected: no output.

- [ ] **Step 4: Commit the docs cleanup**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: align api docs with current client behavior"
```

---

### Task 4: Verify the changed surface end-to-end

**Files:**
- Verify: `test/api_result_test.dart`
- Verify: `README.md`
- Verify: `ARCHITECTURE.md`
- Verify: `lib/src/core/api_client.dart`

- [ ] **Step 1: Run focused tests for the changed behavior**

Run:

```bash
flutter test test/api_result_test.dart
```

Expected: PASS.

- [ ] **Step 2: Run the adjacent client test suite to catch regressions in the public surface**

Run:

```bash
flutter test test/flutter_api_client_test.dart
```

Expected: PASS.

- [ ] **Step 3: Review the final diff for scope**

Run:

```bash
git diff --stat HEAD~3..HEAD
```

Expected: only `lib/src/core/api_client.dart`, `test/api_result_test.dart`, `README.md`, and `ARCHITECTURE.md` changed for this plan’s implementation commits.

- [ ] **Step 4: Commit any final cleanup if needed**

If verification required a final adjustment:

```bash
git add lib/src/core/api_client.dart test/api_result_test.dart README.md ARCHITECTURE.md
git commit -m "chore: polish core cleanup verification follow-ups"
```

If no final cleanup was needed, skip this step.
