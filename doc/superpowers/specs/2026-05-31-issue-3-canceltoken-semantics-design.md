# Design: Issue #3 — CancelToken Semantics

**Date:** 2026-05-31
**Status:** Approved
**Scope:** `flutter_api_client` v1.x — clarify and verify cancellation behavior without a transport rewrite

---

## Problem

Issue #3 claims that `CancelToken` only cancels logical processing and never affects the underlying HTTP transport.

The current code does not fully match that claim:

- `DefaultHttpAdapter` creates a private `http.Client` per request unless the caller injects a shared client.
- When a `CancelToken` fires, the adapter currently calls `client.close()` for owned per-request clients.
- That means the package already attempts physical transport interruption in the default ownership mode.
- However, the public docs still promise a generic “abort” semantic without describing the important distinction between:
  - **owned per-request clients**
  - **shared injected clients**
  - **logical cancellation after the response stream has already started**

This leaves users with the wrong mental model and makes the issue hard to evaluate.

---

## Goal

Make cancellation behavior explicit, tested, and user-facingly correct without changing the transport stack:

1. Document what `CancelToken` guarantees today.
2. Verify the owned-client path is covered by tests.
3. Document the limitation of shared injected clients and `package:http` transport control.
4. Comment on issue #3 with an accurate status update and next-step recommendation.

---

## Non-Goals

- No switch from `package:http` to `dart:io` `HttpClient`.
- No web-specific `AbortController` adapter.
- No new public cancellation API.
- No promise of universal physical abort across all adapters and platforms.

---

## Current behavior to preserve

### Owned default client

For the default adapter mode:

- each request gets its own `http.Client`
- `CancelToken.cancel()` triggers the adapter listener
- the listener calls `client.close()`
- the request should complete as `CancelError`
- unrelated requests are unaffected because they own different clients

### Shared injected client

When a caller passes a shared `http.Client` into `DefaultHttpAdapter`:

- the adapter must not close that shared client on one request cancellation
- cancellation remains logical from the package perspective
- the request should still resolve as `CancelError`
- physical connection abortion is not guaranteed in this mode

This distinction is the core contract that the docs must describe.

---

## Changes

### 1. Clarify `CancelToken` docs

Update the public docs and API comments so they no longer say or imply unconditional transport abort.

New documented contract:

- `CancelToken` cancels the request from the package API perspective.
- With the default `DefaultHttpAdapter` request-owned client mode, cancellation also attempts to interrupt the underlying `package:http` request by closing that request’s private client.
- If the caller injects a shared `http.Client`, the adapter will not close the shared client; in that mode cancellation is logical, not guaranteed physical transport abortion.
- Other adapters may provide different transport-level cancellation guarantees.

Files likely affected:

- `README.md`
- `lib/src/core/cancel_token.dart`
- `lib/src/http/default_http_adapter.dart`
- any summary tables that currently say “abort” without qualification

### 2. Add focused transport-behavior tests

Add tests that prove the documented distinction.

Required coverage:

1. default owned-client path returns `CancelError` when cancelled
2. cancellation of one owned request does not affect another request
3. shared-client mode returns `CancelError` without closing the shared client instance
4. doc-facing behavior remains consistent with current `CancelToken` listener semantics

The tests should verify observable behavior. They should not rely on timing guesses more than necessary.

### 3. Comment on the GitHub issue

After verification, add a comment to issue #3 that says:

- the default adapter already attempts physical interruption for owned per-request clients via `client.close()`
- shared injected clients intentionally are not closed by one request cancellation
- docs/tests were updated to make the current guarantee explicit
- a future adapter rewrite would be the place to pursue stronger platform-specific transport abort semantics

Also leave short triage comments on issues #2 and #1 stating they are next in the queue in that order.

---

## Risks and mitigations

### Risk: overclaiming transport guarantees

Mitigation:
- document guarantees narrowly and specifically by adapter mode
- avoid saying “always aborts the wire request”

### Risk: flaky cancellation tests

Mitigation:
- test observable API outcomes (`CancelError`, unaffected sibling requests, shared client not closed)
- use deterministic mocked or instrumented clients where possible

### Risk: users read old wording elsewhere

Mitigation:
- search and update every user-facing “abort” claim for `CancelToken`

---

## Acceptance criteria

- User-facing docs no longer imply unconditional physical abort semantics.
- `CancelToken` API comments describe owned-client vs shared-client behavior accurately.
- Tests cover the documented cancellation behavior.
- Issue #3 receives a precise status comment grounded in the shipped code.
- Issues #2 and #1 receive brief triage comments indicating order and intent.
