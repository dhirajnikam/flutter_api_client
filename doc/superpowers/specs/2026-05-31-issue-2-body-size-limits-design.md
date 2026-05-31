# Design: Issue #2 — Request and Response Body Size Limits

**Date:** 2026-05-31
**Status:** Approved
**Scope:** `flutter_api_client` v1.x — backward-compatible payload size limits for the default transport

---

## Problem

The package currently buffers request and response bodies in memory without any size cap in the default `package:http` transport path.

That creates two concrete risks:

1. **Response OOM / DoS risk**
   - `DefaultHttpAdapter` reads the full response stream into `chunks`, then allocates a final `Uint8List` for the combined body.
   - A very large API response can exhaust memory on mobile or server environments.

2. **Request OOM / oversized upload risk**
   - Non-multipart request bodies are fully encoded before send.
   - Multipart requests rely on `http.MultipartRequest`, but there is currently no configurable policy gate based on body size.

Issue #2 asks for limits that are opt-in or backward-compatible by default, and that fail predictably when exceeded.

---

## Goal

Add configurable request and response byte limits to the default adapter path without breaking existing users:

1. Support request and response body limits at config level.
2. Allow per-request overrides.
3. Fail with a dedicated typed error when a configured limit is exceeded.
4. Keep defaults backward-compatible (`null` = unlimited).
5. Document that the guarantee applies to the shipped default adapter unless custom adapters implement the same policy.

---

## Non-Goals

- No hard default limit in this change.
- No package-wide streaming API redesign.
- No attempt to enforce limits inside third-party/custom `HttpAdapter` implementations.
- No multipart byte-counting beyond what the underlying `http` request exposes via `contentLength`.
- No separate issue closure/design work for persistent offline queue storage.

---

## Public API changes

### `ApiClientConfig`

Add two optional fields:

```dart
final int? maxRequestBodyBytes;
final int? maxResponseBodyBytes;
```

Thread them through:
- primary constructor
- `withToken`
- `withStorage`
- `test`

### `RequestOptions`

Add two optional per-request overrides:

```dart
final int? maxRequestBodyBytes;
final int? maxResponseBodyBytes;
```

Also add them to `copyWith()`.

### Error model

Add a new typed exception:

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
  final String? direction; // "request" or "response"
}
```

Rationale:
- `ParseError` is the wrong abstraction; this is not a decode failure.
- `HttpError` is also wrong; the server may never have produced a 413.
- Users should be able to distinguish payload policy violations cleanly.

---

## Enforcement design

### Request body limits

Enforce request limits in the default adapter before the request is sent.

#### Non-multipart requests

For `http.Request`:
- if body is `String`, use UTF-8 byte length
- if body is `List<int>`, use `length`
- if body was already encoded upstream, use the actual encoded bytes length
- if the byte count exceeds the effective request limit, throw `PayloadTooLargeError(direction: 'request', ...)` before `client.send()`

#### Multipart requests

For `http.MultipartRequest`:
- use `request.contentLength` if available
- if `contentLength` is known and exceeds the limit, throw `PayloadTooLargeError(direction: 'request', ...)`
- if the underlying request reports unknown length, do not guess or buffer just to compute it in this change

This keeps the implementation boring and avoids hidden extra allocations.

### Response body limits

Enforce response limits while consuming the stream.

Current behavior:
- accumulate all chunks in memory
- only allocate final bytes at the end

New behavior:
- keep a running `received` counter
- before storing or after incrementing with each chunk, compare against the effective response limit
- if exceeded:
  - if the adapter owns the client, close it
  - throw `PayloadTooLargeError(direction: 'response', ...)`
- do not continue buffering once the limit is exceeded

This ensures the adapter fails before fully buffering the oversized payload.

---

## Effective limit resolution

Per-request overrides win over config defaults.

Resolution rules:

```dart
final effectiveMaxRequestBodyBytes =
    options?.maxRequestBodyBytes ?? _config.maxRequestBodyBytes;
final effectiveMaxResponseBodyBytes =
    options?.maxResponseBodyBytes ?? _config.maxResponseBodyBytes;
```

`null` means unlimited.

This must be documented explicitly.

---

## Documentation changes

Update user-facing docs to explain:

- the new config fields
- the per-request overrides
- the new `PayloadTooLargeError`
- that default behavior remains unlimited unless configured
- that the built-in guarantee applies to `DefaultHttpAdapter`

Likely files:
- `README.md`
- `lib/flutter_api_client.dart` package-level docs if the summary table or feature list should mention size limits

---

## Files to change

| File | Change |
|---|---|
| `lib/src/core/api_client.dart` | add config fields and thread them into effective request options resolution |
| `lib/src/core/request_options.dart` | add per-request limit fields + `copyWith` support |
| `lib/src/core/api_exception.dart` | add `PayloadTooLargeError` |
| `lib/src/http/http_adapter.dart` | no contract change required unless comments need clarification |
| `lib/src/http/default_http_adapter.dart` | implement request/response limit enforcement |
| `lib/flutter_api_client.dart` | export remains intact automatically through core export; doc summary may need update |
| `README.md` | document limits and the new error |
| `test/default_http_adapter_test.dart` | add focused limit tests |
| `test/flutter_api_client_test.dart` and/or adjacent config tests | cover new option fields and defaults |

---

## Test strategy

Required coverage:

1. `RequestOptions` and `ApiClientConfig` expose `null` defaults for both limits.
2. Non-multipart request body over limit throws `PayloadTooLargeError` before send.
3. Multipart request with known `contentLength` over limit throws `PayloadTooLargeError` before send.
4. Response stream over limit throws `PayloadTooLargeError` while reading.
5. Under-limit request/response still succeed.
6. Per-request override beats config default.
7. Unlimited (`null`) leaves current behavior unchanged.

Tests should be deterministic and use local/instrumented clients only.

---

## Risks and mitigations

### Risk: accidental breaking change via default caps

Mitigation:
- keep defaults `null`
- explicitly test unlimited default behavior

### Risk: extra allocations while measuring size

Mitigation:
- use already-encoded body lengths for non-multipart requests
- use stream counters for responses
- do not re-buffer just to compute size

### Risk: multipart `contentLength` uncertainty

Mitigation:
- enforce only when the length is known
- document this limit of the current implementation

### Risk: confusing error handling for callers

Mitigation:
- add a dedicated `PayloadTooLargeError`
- document how it differs from `ParseError` and `HttpError`

---

## Acceptance criteria

- `ApiClientConfig` supports optional request/response body byte limits.
- `RequestOptions` supports per-request overrides for both limits.
- Oversized request or response payloads in `DefaultHttpAdapter` fail with `PayloadTooLargeError`.
- `null` defaults preserve existing unlimited behavior.
- README/docs explain the new options and the default-adapter scope.
- Focused and full test verification pass.
