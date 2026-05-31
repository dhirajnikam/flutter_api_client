# Design: Backward-Compatible Core Cleanup

**Date:** 2026-05-31
**Status:** Approved
**Scope:** `flutter_api_client` v1.x — internal cleanup, documentation correction, no public API breakage

---

## Problem

The package currently has three maintainability issues in the core HTTP path:

1. **Docs and architecture drift**
   - `README.md` and `ARCHITECTURE.md` still describe `CustomApiResponse<T>` and a public `client.request()` flow.
   - The shipped code returns `ApiResult<T>` from the HTTP verb methods and does not expose the documented dual-result API anymore.
   - This misleads consumers and future maintainers.

2. **Weak HTTP parse failure classification**
   - `ParseError` exists in the error model, but the HTTP client does not use it for malformed JSON or invalid `ResponseType.json` bodies.
   - The current `_decode()` path swallows malformed JSON and returns `null`, which can later collapse into a `TypeError` and be wrapped as `UnknownError`.
   - That loses actionable error information and makes client behavior harder to reason about.

3. **`ApiClient` carries too much internal policy in one class**
   - Request option normalization, header assembly, multipart/body preparation, transport dispatch, and response decoding are all implemented inline.
   - The code works, but the responsibilities are not clearly separated, making behavior changes riskier than necessary.

---

## Goal

Improve correctness and maintainability without breaking package consumers:

1. Keep the public HTTP API and behavior shape stable for existing callers.
2. Make response parsing failures explicit and typed.
3. Separate `ApiClient` internals into smaller, single-purpose helpers.
4. Bring package documentation and architecture documentation back into sync with the actual code.

---

## Non-Goals

- No public API breaking changes.
- No interceptor contract redesign.
- No package-wide file reorganization.
- No changes to GraphQL semantics unless directly required by shared HTTP behavior.
- No new features beyond the cleanup itself.

---

## Changes

### 1. Correct the public contract in docs

Update `README.md` and `ARCHITECTURE.md` to match the shipped code:

- Document `ApiResult<T>` as the result type returned by `get/post/put/patch/delete`.
- Remove stale references to `CustomApiResponse<T>` and `client.request()` from user-facing guidance.
- Update any architecture descriptions that still claim two parallel result paths.
- Document the actual error classification path for HTTP parsing.

This is a correctness fix for the package contract, not a feature change.

### 2. Make JSON decode failures return `ParseError`

When `ResponseType.json` is requested:

- A successful 2xx response with malformed JSON must produce `Failure(ParseError(...))`.
- A successful 2xx response with a non-empty body that is clearly plain text / HTML must also produce `Failure(ParseError(...))`.
- A successful 2xx response with an empty body remains allowed and should decode to `null`.

Non-2xx responses keep the current `Failure(HttpError(...))` path. Their body may still be decoded best-effort for inclusion in `HttpError.body`, but parse failure there must not replace the HTTP-status failure with `ParseError`.

This preserves the user-visible distinction:

- transport or server failure → `HttpError`, `NetworkError`, `TimeoutError`, etc.
- payload contract failure on a successful HTTP response → `ParseError`

### 3. Decompose `ApiClient` internals without moving the public surface

Keep `ApiClient` in `lib/src/core/api_client.dart`, but reduce inline policy by extracting private helpers inside the file.

The helpers should separate these concerns:

- effective request option resolution
- request header assembly
- adapter payload construction (JSON body vs multipart form data)
- success/error response decoding

The public methods remain:

```dart
Future<ApiResult<T>> get<T>(String endpoint, { ... });
Future<ApiResult<T>> post<T>(String endpoint, dynamic data, { ... });
Future<ApiResult<T>> put<T>(String endpoint, dynamic data, { ... });
Future<ApiResult<T>> patch<T>(String endpoint, dynamic data, { ... });
Future<ApiResult<T>> delete<T>(String endpoint, { ... });
```

No new public types are introduced.

### 4. Define empty-body behavior explicitly

For `ResponseType.json`:

- `2xx` + empty body → success with `null` decoded payload
- non-`2xx` + empty body → `Failure(HttpError(...))` with message from `ResponseHandler`

This keeps existing practical support for `204 No Content` style endpoints while removing ambiguity from the implementation.

---

## Detailed behavior rules

### Success path

For a `2xx` response:

- `ResponseType.bytes` → return raw bytes
- `ResponseType.plainText` → return UTF-8 decoded string
- `ResponseType.stream` → preserve current behavior (`bodyBytes`)
- `ResponseType.json`
  - empty body → `Success<T>(null as T, ...)` via the existing typed path semantics
  - valid JSON + optional decoder succeeds → `Success<T>(decoded, ...)`
  - invalid JSON / invalid text payload → `Failure(ParseError(...))`

### Error path

For a non-`2xx` response:

- Keep current `HttpError` creation and status code propagation.
- Preserve best-effort body decoding for `HttpError.body` where possible.
- Do not convert non-`2xx` responses into `ParseError`; the HTTP status remains the primary failure.

### Unknown exceptions

Only truly unexpected exceptions should become `UnknownError`.

A payload parse problem in the normal HTTP path is expected enough to classify as `ParseError` and should not fall through to the catch-all branch.

---

## Files to change

| File | Change |
|------|--------|
| `lib/src/core/api_client.dart` | Extract private helpers, tighten parse/empty-body handling, preserve public API |
| `README.md` | Remove stale `CustomApiResponse` / `client.request()` documentation, document actual `ApiResult<T>` behavior |
| `ARCHITECTURE.md` | Align architecture narrative with current implementation and error classification |
| `test/api_result_test.dart` | Add coverage for malformed JSON, invalid text payloads, and empty-body success semantics |
| `test/flutter_api_client_test.dart` and/or adjacent tests | Update or extend documentation-aligned behavioral checks if needed |

---

## Test strategy

Add or update focused tests for the changed behavior:

1. `2xx` + valid JSON → `Success`
2. `2xx` + malformed JSON → `Failure(ParseError)`
3. `2xx` + HTML/text body under `ResponseType.json` → `Failure(ParseError)`
4. `204` or `200` with empty body under `ResponseType.json` → success with `null` payload
5. non-`2xx` + malformed/empty body → still `Failure(HttpError)`

The tests must prove the distinction between HTTP-status failures and payload-parse failures.

---

## Risks and mitigations

### Risk: stricter parse behavior could expose latent server issues

Mitigation:
- This only affects responses that were already malformed for a JSON request.
- Returning `ParseError` is safer and more diagnosable than returning `null` or surfacing `UnknownError`.

### Risk: empty-body handling around generics could be surprising

Mitigation:
- Keep the existing practical behavior shape for no-content success.
- Cover it explicitly in tests and document it.

### Risk: doc corrections could miss stale references

Mitigation:
- Search for `CustomApiResponse` and `client.request()` references across docs/tests and update all user-facing mentions.

---

## Acceptance criteria

- Public API remains backward-compatible for current callers.
- HTTP verb methods continue returning `ApiResult<T>`.
- Successful malformed JSON/text payloads now return `Failure(ParseError)`.
- Empty successful JSON responses are handled explicitly and covered by tests.
- `README.md` and `ARCHITECTURE.md` no longer describe removed or non-existent response APIs.
- A focused test run covering the changed behavior passes.
