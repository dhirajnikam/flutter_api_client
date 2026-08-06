## 1.6.0

**Release Date**: 2026-08-06  
**Type**: Minor Release (additive)  
**Breaking Changes**: None (fully backward compatible with 1.5.0)

This release adds optimistic offline mutations and full control over replay
ordering: local data can be updated optimistically, the resulting API call is
queued while offline, and the queue replays with customizable priority and
ordering.

### Added

* **Optimistic offline mutations** — `OfflineMutations`. Call `mutate()` instead
  of `client.post/put/patch/delete` with `apply` / `rollback` callbacks: `apply`
  updates your local store immediately, the request is sent, and if the device
  is offline it is queued for replay while the optimistic state is kept. If the
  server is reached and rejects the write (non-transient), `rollback` runs at
  once; if a queued write is later dead-lettered during replay, `rollback` runs
  then. The package stays model-agnostic — it calls your closures, so it works
  with Hive, Isar, Drift, Bloc, Riverpod, or a plain map.
* **Replay priority** — `QueuedRequest.priority` (default `0`, higher replays
  first; ties break on `createdAt` then `id`). Both queue stores replay in this
  order. `OfflineQueueInterceptor` gains a `priorityOf` callback to set a
  priority per auto-queued request.
* **Custom replay ordering** — `OfflineQueueReplayer.compare`, an optional
  `Comparator<QueuedRequest>` that overrides replay order entirely (order by
  endpoint, method, custom metadata, anything). Falls back to priority + oldest
  when null.
* **Replay outcome hook** — `OfflineQueueReplayer.onOutcome` +
  `ReplayOutcome { succeeded, reEnqueued, deadLettered }`, awaited per request
  (this is how `OfflineMutations` commits/rolls back).
* **Auto-replay on reconnect** — `OfflineAutoReplay`. Feed it a `Stream<bool>`
  (true = online) from any connectivity source (`connectivity_plus`, a ping,
  a test controller — no dependency bundled) and it replays on reconnect,
  coalescing overlapping triggers so the queue is never drained concurrently.
  `trigger()` is public for a manual "retry now". (For scheduled retries and
  replay-on-start, see `OfflineSyncManager` from 1.5.0 — both are exported.)

### Notes

* `rollback` closures are held in memory keyed by request id. A write queued in
  one app run, then dead-lettered after a restart, has no rollback to call — the
  queued request is dropped but local state is not reverted. Use an `apply` that
  writes a "pending" marker your startup reconciles if you need restart-durable
  rollback (Dart cannot serialize closures).

## 1.5.0

**Release Date**: 2026-08-01  
**Type**: Minor Release (additive)  
**Breaking Changes**: None (fully backward compatible with 1.4.0)

This release fills in the remaining blanks around offline and resilience:
persistent caching, hands-free offline sync, a circuit breaker, and
functional `ApiResult` helpers. Everything is new API surface — nothing
existing changed.

### Added

* **`HiveCacheStore`** — a persistent, Hive-backed `CacheStore` (mirroring
  `HiveOfflineQueueStore` on the write side). Cached responses now survive
  app restarts, so `CachePolicy.cacheFirst`/`cacheOnly` deliver real offline
  reads. Optional `maxEntries` cap evicts oldest-`savedAt` first; corrupt
  records read as misses and are deleted rather than thrown.
* **`OfflineSyncManager`** — closes the loop on the offline pipeline. Feed
  it any `Stream<bool>` connectivity signal (e.g. mapped from
  `connectivity_plus`) and it replays the offline queue automatically when
  the device comes online, re-schedules a pass (after `retryDelay`) while
  transient failures remain, cancels the schedule when connectivity drops,
  and reports every pass through `onReport`. `replayOnStart` drains writes
  queued in a previous session at app launch; `syncNow()` runs a pass on
  demand.
* **`CircuitBreakerInterceptor`** — fails fast when an origin looks down
  instead of letting every request wait out its timeout. Per-host circuits:
  `closed` → `open` after `failureThreshold` consecutive transport failures
  (network/timeout errors and HTTP 5xx) → one `halfOpen` probe after
  `cooldown` → closed on success. Rejections surface as `NetworkError` (no
  new exception type, so exhaustive `ApiException` switches keep compiling);
  4xx responses and cancellations never trip the circuit. `onStateChange`
  exposes transitions; `stateFor(host)` reads current state.
* **`ApiResult` functional helpers** — `flatMap` (chain result-producing
  steps), `mapError` (translate errors at a boundary), `getOrElse`
  (fallback value), and chainable `onSuccess`/`onFailure` taps.

## 1.4.0

**Release Date**: 2026-07-30  
**Type**: Minor Release (additive)  
**Breaking Changes**: None (fully backward compatible with 1.3.x)

This release makes the offline story smooth end-to-end — queued writes now
replay against exactly the URL they originally targeted, the built-in stores
survive a crash mid-replay, and both ends of the pipeline gained observability
hooks — and ships a full-codebase reliability sweep (caching, retries, dedup,
auth storage, transport, and the spec generators). Every change is additive;
existing code and previously persisted queue records keep working unchanged.

### Added

* **`PeekableOfflineQueueStore`** — an optional capability interface for
  offline stores (`peekAll()` reads pending requests without removing them).
  Both built-in stores (`InMemoryOfflineQueueStore`, `HiveOfflineQueueStore`)
  implement it. When the store is peekable, `OfflineQueueReplayer` keeps every
  request persisted until it is individually settled, so a crash mid-replay no
  longer loses the not-yet-sent tail (delivery is at-least-once). Custom
  stores that only implement `OfflineQueueStore` keep the legacy drain-based
  path unchanged.
* **`QueuedRequest.queryParameters` / `QueuedRequest.baseUrlOverride`** —
  queued writes now persist the query string and base-URL override they were
  issued with, and the replayer restores them, so a replayed
  `POST /items?draft=true` no longer silently becomes `POST /items`. Records
  persisted by older versions parse fine (the new fields are optional).
* **`OfflineQueueInterceptor.onQueued`** — optional callback fired with the
  stored record after a request is queued. Use it for "saved offline, will
  sync" UI or to schedule a replay pass.
* **`OfflineQueueReplayer.onDeadLetter`** — optional callback fired with the
  request (and final error) whenever a queued write is dropped, either because
  the server rejected it or it exhausted `maxAttempts`.
* **QUERY replay** — `OfflineQueueReplayer` now replays queued `QUERY`
  requests through `ApiClient.query` instead of falling back to POST.

### Fixed

* **Replay no longer double-sends on overlapping calls.** Concurrent
  `OfflineQueueReplayer.replay()` invocations (e.g. from a chatty connectivity
  listener) now share a single in-flight pass and return the same report.
* **A queueing failure no longer masks the network error.** If the store
  throws while persisting (unserialisable body, disk full), the caller still
  receives the original `NetworkError`/`TimeoutError` instead of an
  `UnknownError` from the store.
* **Multipart requests are no longer queued.** File/stream payloads cannot be
  persisted and replayed faithfully; previously they could poison a persistent
  store's JSON encoding at enqueue time.

### Added (reliability sweep)

* **`CachedTokenStorage.onWriteError`** — background delegate writes are now
  chained in order and their failures reported through this optional callback
  instead of surfacing as unhandled zone errors; `clear()` flushes pending
  writes first so an in-flight token write can no longer land *after* logout
  and resurrect the credential.
* **`ResponseHandler(charset: …)` / `PrettyLogger(charset: …)`** — both now
  honour a configurable charset (still UTF-8 by default), and `ApiClient`
  passes its configured `charset` into the default handler, so error messages
  from non-UTF-8 APIs decode correctly.

### Fixed (core client)

* **Cache TTL no longer slides on every hit.** Serving an entry from the cache
  re-wrote it with a fresh `savedAt`, so a steadily re-read entry never
  expired and the origin was never re-contacted. Freshness is now measured
  from when the body was actually fetched.
* **A 304 whose cache entry was evicted mid-flight re-fetches** the full body
  (dropping the stale `If-None-Match`) instead of surfacing an empty
  `HttpError 304` to the caller.
* **`cacheOnly` misses fail fast** — the synthetic 504 is no longer routed
  through retry backoff.
* **Streamed responses discarded by a chain restart are drained**, releasing
  the adapter's owned HTTP client (previously leaked once per retry/refresh
  on the streaming path).
* **The request timeout now covers the response body read** in the buffered
  path — a server that sends headers then stalls the body surfaces a
  `TimeoutError` instead of hanging forever.
* **Dedup cancellation isolation.** A cancelled leader no longer fails
  coalesced followers (they fall back to their own request), and a follower
  whose own token fires stops waiting immediately instead of blocking on the
  leader.
* **Interceptor cleanup on retry-depth exhaustion.** The depth-limit error now
  runs interceptors' `onError` (without allowing restarts), so dedup releases
  its in-flight entry instead of stalling every future identical request for
  the full `waitTimeout`.
* **`ETag` and `Retry-After` response headers are read case-insensitively.**
* Documented that the request identity key deliberately includes
  `Authorization` (credential isolation for cache/dedup).

### Fixed (spec tooling & GraphQL)

* **Generated YAML is now always parseable and type-faithful**: backslashes,
  newlines, tabs, and control characters are properly escaped; numeric-looking
  and YAML-keyword strings (including map keys like `'200'`) are quoted.
* **OpenAPI documents are valid for response-less endpoints** — a default
  `204 No Content` entry is emitted instead of an empty (invalid) `responses`
  object, matching `SpecMockAdapter`'s behavior.
* **`ApiSpec.servers` is additive again**: `baseUrl` is always emitted first,
  as documented, instead of being replaced.
* **`SpecMockAdapter`**: `statusOverrides` no longer throws for endpoints with
  no declared responses; GraphQL `statusOverrides` apply even when the
  operation declares no `errors`; bodyless requests are validated against the
  declared schema; literal path segments now beat `{param}` placeholders when
  routes are ambiguous.
* **`TestGenerator`**: generated files compile for GET/DELETE endpoints with
  request schemas; the 422 validation test is only emitted when the schema
  actually has required members; `QUERY` endpoints generate real tests via
  `client.query`; all interpolated strings (titles, paths, base URLs) are
  escaped.
* **`BackendGuideGenerator`** renders FastAPI routes with `{param}` templates
  instead of Express-style `:param`.
* **`GraphQLClient`** surfaces the underlying transport error via
  `networkError` when the response has no GraphQL envelope (e.g. an HTML
  captive-portal page), instead of returning an empty response.
* **`Schema.enumValues` are enforced for integer/number/boolean** fields, not
  just strings.
* Doc corrections: real `--only` generator names, current dependency version
  in API_SERVICES_GUIDE, de-versioned README comparison table.

## 1.3.1

**Release Date**: 2026-07-18  
**Type**: Patch Release (bug fixes)  
**Breaking Changes**: None

Fixes divergence between the generated OpenAPI JSON and YAML documents, and
makes the generated test file `dart format`-clean out of the box.

### Fixed

* **OpenAPI YAML no longer drops empty collections.** The YAML serializer
  silently omitted any key whose value was an empty list or map, so the YAML
  document diverged from the JSON one: example payloads lost empty arrays
  (`{"users": [], "total": 0}` rendered as just `total: 0`), and — more
  seriously — `security: []` (OpenAPI's marker for a public endpoint) vanished
  from the YAML, changing the described contract. Empty collections and nulls
  now render inline so both formats stay faithful.
* **OpenAPI JSON no longer emits `"summary": null` / `"description": null`.**
  These fields are now omitted when absent, matching the OpenAPI schema (they
  must be strings, not null).
* **Generated YAML uses canonical block-sequence indentation.** List items no
  longer hang their mapping on an over-indented following line; the first key
  now sits on the `-` line with aligned continuations.
* **Generated test file is `dart format`-clean.** The `TestGenerator` no longer
  leaves stray blank lines before closing braces, and `dart run
  flutter_api_client:gen --tests` now runs the SDK formatter over the emitted
  `test/api_spec_test.dart` so long inline body literals are wrapped correctly.

## 1.3.0

**Release Date**: 2026-07-17  
**Type**: Minor Release (additive)  
**Breaking Changes**: None (fully backward compatible with 1.2.0)

This release opens up the client's customization surface. Everything that was
previously hard-coded is now configurable, and every new option is optional with
a default that reproduces the pre-1.3.0 behaviour exactly — existing code is
unaffected.

### Added

* **Configurable default headers & locale** on `ApiClientConfig`: `defaultAccept`
  (`application/json`), `defaultAcceptLanguage` (`en`), `defaultContentType`
  (`application/json`), and `defaultHeaders` (replaces the whole built-in
  default-header block when set). Per-request `headers`/`extraHeaders` still
  override these case-insensitively.
* **Pluggable serialization**: `RequestBodySerializer` (default
  `JsonRequestBodySerializer`), `ResponseJsonCodec` (default
  `DefaultResponseJsonCodec`), and `Charset` (default `Utf8Charset`), wired
  through `ApiClientConfig.bodySerializer` / `responseJsonCodec` / `charset`.
  Send/parse form-urlencoded, non-UTF-8, or custom JSON without swapping the
  transport.
* **Configurable query-string encoding** via `QueryEncoder` (list format
  `repeated`/`brackets`/`comma`, nested style `brackets`/`dotted`, and
  null-inclusion), exposed as `ApiClientConfig.queryEncoder`. `buildUri` /
  `buildQueryString` gain an optional `encoder` argument; their existing
  signatures are unchanged.
* **Custom retry backoff**: `RetryPolicy.backoff` — a `Duration Function(int
  attempt)` that replaces the built-in exponential formula. The result is still
  capped at `maxDelay`, jittered when `useJitter` is on, and yields to a server
  `Retry-After`.
* **Configurable auth header name**: `AuthInterceptor.headerName` /
  `ApiClientConfig.authHeaderName` (default `Authorization`).
* **Configurable success boundary**: `ApiClientConfig.isSuccessStatus`
  (default `200 <= code < 300`) decides which responses become `Success`.
* **`ClientCustomization`** bundle so the `withToken` / `withStorage` / `test`
  factories expose all of the above through a single `customization` parameter.

### Notes

* If you rename the auth header via `authHeaderName`, the bundled `PrettyLogger`
  / `CurlLogger` will not redact it by default (they key on `authorization`).
  Add your header name to their `redactHeaders` set to keep the token out of
  logs.
* The `comma` query list format emits a literal comma separator
  (`ids=1,2,3`), encoding each element individually.

## 1.2.0

**Release Date**: 2026-07-07  
**Type**: Minor Release (additive)  
**Breaking Changes**: None (fully backward compatible with 1.1.0)

### Added
* **HTTP `QUERY` method**: new `ApiClient.query<T>(endpoint, data, …)` convenience
  method for the safe, idempotent, cacheable QUERY method, which carries a request
  body so complex queries live in the body instead of the URL. Standardized in
  RFC 10008: <https://www.rfc-editor.org/rfc/rfc10008.html>.

### Changed
* **Wider install compatibility**: the codegen builders no longer `auto_apply` to
  every dependent (`auto_apply: none`). Apps that only use the runtime HTTP client
  no longer trigger the analyzer-backed build step. If you use the generator,
  opt the builders in via your project's `build.yaml` — see the README quick-start.

## 1.1.0

**Release Date**: 2026-06-23  
**Type**: Minor Release (streaming, offline-queue replay, resilience + auth hardening, audit fixes)  
**Breaking Changes**: None (additive; `RequestOptions.retryPolicy`/`cachePolicy` are now statically typed)

This release adds a true streaming download path and an offline-queue replay
engine, hardens retries / caching / dedup / GraphQL APQ and the concurrent-401
auth refresh flow, and fixes a set of codegen and documentation issues found in
a full audit. Fully backward compatible with 1.0.3.

### Security
* **`AuthInterceptor`**: the token-change fingerprint used by the concurrent-401
  staleness guard now uses SHA-256 instead of `String.hashCode`, removing the
  collision risk that could mask a real token rotation (and fire a redundant
  refresh) and making the "non-reversible" guarantee actually hold. The
  fingerprint remains internal and is stripped before the wire. The `refresh`
  contract is now documented explicitly: it must persist the new token before
  completing; wrap slow backends in `CachedTokenStorage`.

### Added
* **Offline queue replay engine**: `OfflineQueueReplayer` drains the queue in
  `createdAt` order and re-issues each request through the client (re-attaching
  a fresh auth token). Transient failures are re-enqueued with an attempt
  count; requests are dead-lettered after `maxAttempts` to prevent poison-message
  loops. `QueuedRequest` now carries an `attempts` field (defaults to 0 for
  existing persisted records).
* **Real streaming responses**: `ApiClient.stream()` returns an
  `HttpStreamResponse` whose body is delivered as a live byte stream instead of
  being buffered. `DefaultHttpAdapter` implements the new optional
  `StreamingHttpAdapter` capability; adapters that don't support it fall back to
  buffering transparently.
* **`MemoryCacheStore` byte bound**: optional `maxBytes` cap so the cache evicts
  by total body size, not just entry count.

### Fixed
* **Response body copied three times**: the receive path now uses a
  `BytesBuilder`, coalescing the body in a single pass instead of
  `expand().toList()` + `Uint8List.fromList`.
* **`Retry-After` could wedge a request**: the header is now clamped to
  `maxDelay`, negative values are rejected, and the HTTP-date form is parsed.
* **Correlated retry jitter**: retries now use a shared RNG and full jitter
  (uniform in `[0, capped]`) so concurrent clients decorrelate under load.
* **Dedup deadlock on retry**: a retried deduped request no longer awaits its
  own in-flight completer; followers also time out (`waitTimeout`) instead of
  hanging if a leader never completes.
* **GraphQL APQ hash**: the default `hashQuery` now produces a real SHA-256 hex
  digest, so the persisted-query fast path can match a server-registered
  document (the old placeholder guaranteed a miss + full-document fallback). The
  fallback request after a `PersistedQueryNotFound` miss now carries the full
  document **and** the `sha256Hash` together, so the server can register the
  query and later calls hit the fast path (previously the hash was dropped on
  fallback, so APQ could never engage).
* **Auth token could leak past an explicit `includeToken: false`**: when a
  request supplied both a method-level `includeToken: false` and a non-null
  `RequestOptions`, the options default (`true`) silently won and the
  `Authorization` header was attached anyway. Token attachment is now fail-safe:
  it requires *both* sources to permit it.
* **Duplicate `Content-Type` headers**: a caller header override spelled with
  different casing (e.g. `content-type`) no longer emits a second, conflicting
  `Content-Type`; header merging is now case-insensitive (latest value wins).
* **`stream()` leaked the transport client on error responses**: a non-2xx
  streaming response now drains the unbuffered body so the streaming adapter's
  owned `http.Client` is closed exactly once instead of leaking.
* **`TestGenerator`**: generated test source now escapes `'`, `$`, `\`, and
  newlines in example bodies (previously emitted non-compiling Dart), and skips
  endpoints whose HTTP method the client has no verb for (e.g. `HEAD`) instead
  of emitting an uncompilable `client.head(...)` call.
* **`CurlLogger`**: uses the portable `'\''` POSIX idiom to embed single quotes,
  so emitted cURL commands stay paste-able when a header or body contains a quote.
* **`bin/gen.dart`**: relative-import computation normalises path separators, so
  `dart run flutter_api_client:gen` works on Windows.
* **`Schema.validate`**: an unknown schema `type` now fails validation instead
  of silently passing.
* **`InMemoryOfflineQueueStore.drain`**: returns requests in `createdAt` order,
  matching the `OfflineQueueStore` contract and `HiveOfflineQueueStore`.
* **`CachedTokenStorage.clear`**: awaits the delegate before dropping the cache,
  so a failed delegate clear no longer resurrects a "cleared" token on next read.

### Changed
* **`RequestOptions.retryPolicy` / `cachePolicy`** are now typed
  `RetryPolicyInterface?` / `CachePolicyInterface?` (declared in `core`) instead
  of `Object?`, giving compile-time safety. Existing code passing `RetryPolicy`
  / `CachePolicy` instances is unaffected.
* **`CachePolicy.staleWhileRevalidate`** docs now describe the actual behaviour
  (serve-fresh, revalidate-on-stale); removed a dead internal revalidate header.

### Deprecated
* `ApiClientInterface` — single-implementation interface with no injection
  point. Depend on `ApiClient` directly (Dart can fake concrete classes).
  Scheduled for removal in 2.0.0.

### Dependencies
* Promoted `crypto` to a direct dependency (used for APQ hashing).

---

## 1.0.3

**Release Date**: 2026-05-31  
**Type**: Patch Release (Security hardening + Dependency refresh)  
**Breaking Changes**: None

This release hardens request handling and logging, refreshes direct dependencies to current compatible versions, and aligns the package documentation with the shipped runtime behavior. Fully backward compatible with 1.0.2.

### Fixed
* **Internal Header Leakage**: Client-only `x-fac-*` control headers are now stripped before requests reach the transport layer
* **Retry Safety**: Response-based retries now respect `safeMethods`, preventing automatic retries of mutating methods unless explicitly configured
* **Offline Queue Credentials**: `OfflineQueueInterceptor` no longer persists `Authorization` headers, preventing stale-token replay from on-disk queues
* **Logger Redaction**: cURL and pretty loggers now redact sensitive JSON body keys and sensitive response headers more consistently
* **Builder Compatibility**: Updated generated-spec builder logic for current `source_gen` / analyzer APIs

### Documentation
* **README.md**: Added explicit permission guidance, corrected retry/cache/offline-queue semantics, refreshed logger examples, and updated test commands
* **TESTING.md**: Switched package test instructions to `flutter test` and aligned filters/examples with the current workflow
* **ARCHITECTURE.md**: Updated retry and cache behavior descriptions to match the runtime implementation
* **Library Dartdoc**: Refreshed release notes in `lib/flutter_api_client.dart`

### Quality Improvements
* **Dependency Freshness**: Bumped direct runtime/tooling constraints to current compatible versions and removed the unused direct `meta` dependency
* **Regression Coverage**: Added tests for internal header stripping, non-safe retry behavior, offline queue auth stripping, and logger redaction of sensitive payloads
* **Verification**: `dart analyze`, `flutter test`, `flutter test` in `example/`, `dart pub outdated --json --up-to-date --no-dev-dependencies --no-dependency-overrides`, and `dart pub downgrade --no-example && dart analyze`

### Upgrade Guide
```yaml
dependencies:
  flutter_api_client: ^1.0.3
```

No code changes required for existing callers.

## 1.0.2

**Release Date**: 2026-05-31  
**Type**: Patch Release (Core correctness + Documentation)  
**Breaking Changes**: None

This release tightens HTTP response parsing, improves maintainability in the core request path, and aligns the package documentation with the shipped API surface. Fully backward compatible with 1.0.1.

### Fixed
* **HTTP Parse Classification**: Successful `ResponseType.json` responses that contain malformed JSON now return `Failure(ParseError)` instead of degrading into nullable/unknown behavior
* **Text/HTML Payload Handling**: Successful JSON-mode responses with obvious text or HTML payloads now return `Failure(ParseError)`
* **No-Content Success Semantics**: Empty successful JSON responses are handled explicitly and continue to decode to `null`

### Internal Improvements
* **ApiClient Decomposition**: Split request option resolution, header construction, payload building, and response decoding into smaller private helpers
* **Error Mapping**: Kept non-2xx malformed payloads classified as `HttpError` so HTTP status remains the primary failure signal

### Documentation
* **README.md**: Removed stale `CustomApiResponse` / `client.request()` documentation and aligned all HTTP result examples with `ApiResult<T>`
* **ARCHITECTURE.md**: Updated the architecture narrative to reflect the shipped result type and parse behavior
* **Library Dartdoc**: Refreshed release notes in `lib/flutter_api_client.dart`

### Quality Improvements
* **Regression Coverage**: Added tests for malformed successful JSON, successful HTML/text payloads in JSON mode, explicit empty-body success handling, and malformed non-2xx payload preservation
* **Verification**: `flutter test` passes with 138 tests

### Upgrade Guide
```yaml
dependencies:
  flutter_api_client: ^1.0.2
```

No code changes required for existing callers.

## 1.0.1

**Release Date**: 2026-05-12  
**Type**: Patch Release (Bug fixes + Documentation)  
**Breaking Changes**: None

This release focuses on improving documentation, fixing generated code issues, and ensuring the package follows all industry standards. Fully backward compatible with 1.0.0.

### Fixed
* **Test Generation**: Fixed undefined `spec` reference in generated test files (`test_generator.dart`)
  - Generated tests now correctly import and reference the actual spec variable
  - `spec` placeholder replaced with actual spec variable name (e.g., `mySpec`)
  - All generated tests pass without manual modifications
* **Import Cleanup**: Fixed unused import warnings in generated test scaffolds
* **Example Tests**: Improved example test structure with proper package imports
* **Code Formatting**: Formatted 64 Dart files across the entire codebase for consistency

### Documentation
* **README.md**: Major enhancement with 1000+ lines of comprehensive documentation
  - Added "Features at a Glance" section documenting 55+ features across 6 categories
  - Enhanced feature comparison table (dio vs http vs flutter_api_client)
  - Added "Key Advantages" section highlighting unique benefits
  - Updated all version references from 2.0.0 to 1.0.1
  - Improved quick start guide with clearer examples
  - Better table of contents organization
* **CONTRIBUTING.md** (NEW): Complete contribution guidelines
  - Code style conventions following Effective Dart
  - Commit message format using Conventional Commits
  - Pull request process and templates
  - Testing requirements and examples
  - Project structure overview
  - 256 lines of guidance for contributors
* **ARCHITECTURE.md** (NEW): Internal architecture documentation
  - High-level system architecture diagrams
  - Component interaction flows and data flow
  - Detailed interceptor chain explanation
  - Design decisions and rationale for key features
  - Performance considerations and optimizations
  - Token storage architecture
  - Future roadmap and planned enhancements
  - 467 lines of technical documentation
* **example/README.md**: Completely rewritten
  - Tab-by-tab feature demonstrations
  - Real API usage examples (DummyJSON, JSONPlaceholder, Dog CEO, Open Trivia)
  - Running instructions for all platforms (iOS, Android, Web, Desktop)
  - Code structure overview
  - Key takeaways and learning objectives
  - 140 lines of practical guidance
* **docs/RELEASE_NOTES_1.0.1.md** (NEW): Comprehensive release documentation
  - Detailed bug fixes and improvements
  - Feature highlights and statistics
  - Migration guide (no migration needed)
  - Industry standards compliance checklist
  - Future roadmap for 1.1.0
* **docs/PACKAGE_REVIEW_SUMMARY.md** (NEW): Complete quality assessment
  - Production readiness checklist
  - Code quality metrics (134 tests, 0 errors)
  - Security review
  - Performance review
  - Compatibility matrix
* **API_SERVICES_GUIDE.md**: Updated all version references to 1.0.1
* **TESTING.md**: Enhanced with additional test patterns
* **lib/flutter_api_client.dart**: Expanded library-level documentation
  - Comprehensive feature overview in dartdoc
  - Quick start code example
  - Version 1.0.1 release notes

### Quality Improvements
* **Test Suite**: All 134 tests passing (100% pass rate)
  - Zero test failures
  - Improved test coverage for edge cases
  - Fixed flaky tests in example project
* **Code Analysis**: 
  - Zero errors
  - 2 acceptable warnings (generated files)
  - 65 info messages (style suggestions, SDK deprecations)
  - All critical issues resolved
* **Industry Standards Compliance**:
  - ✅ Semantic Versioning (SemVer 2.0.0)
  - ✅ Conventional Commits documentation
  - ✅ Keep a Changelog format
  - ✅ Effective Dart style guide
  - ✅ MIT License
  - ✅ Comprehensive examples
  - ✅ API documentation (dartdoc)
  - ✅ Architecture documentation
  - ✅ Contributing guidelines

### Statistics
* **Documentation**: 10 comprehensive markdown files (5 new, 5 updated)
* **Tests**: 134 passing (previously 107, more edge cases discovered and tested)
* **Code Quality**: 64 files formatted, 0 errors, >90% coverage maintained
* **Package Size**: No significant change from 1.0.0

### Notes
* This release maintains 100% backward compatibility with 1.0.0
* No dependency updates required
* All features from 1.0.0 work identically
* Recommended for all users to upgrade for better documentation and fixed test generation

### Upgrade Guide
```yaml
dependencies:
  flutter_api_client: ^1.0.1
```

Then run:
```bash
flutter pub upgrade flutter_api_client
```

No code changes required. Regenerate tests if using spec system:
```bash
dart run flutter_api_client:gen --only tests
```

## 1.0.0

Major redesign. Bumps the package above feature parity with `dio` while
keeping the surface focused. **Breaking changes** — see the migration
section in the README.

### Added (GraphQL)
* **`GraphQLClient`** wrapper around `ApiClient` with `query`, `mutation`,
  typed `GraphQLResponse<T>`, optional decoder for the `data` field,
  GraphQL error parsing, and automatic-persisted-queries (APQ) support.
* **`GraphQLException` + `GraphQLError`** types for typed error handling.
* **`ApiSpec.graphql(...)`** section + `GraphQLOperation` /
  `GraphQLErrorExample`. Declare queries, mutations, and subscriptions
  alongside REST endpoints.
* **`SpecMockAdapter`** now routes `POST /graphql` (or your chosen
  endpoint) to declared operations, validates variables against their
  `Schema`, and supports `statusOverrides: {'GQL OperationName': code}`.
* **`MarkdownDocGenerator`** renders a GraphQL section per operation.
* **`BackendGuideGenerator`** renders a GraphQL section: operation table,
  derived SDL (`Query` / `Mutation` / `Subscription`), variable tables,
  example `data`, resolver skeletons, and optional framework snippets
  (Express + Apollo, FastAPI + Strawberry, Go + gqlgen). The acceptance
  checklist now covers GraphQL operations too.

### Added
* **Pluggable `HttpAdapter`** — swap `package:http` for `cupertino_http`,
  `cronet_http`, or a `MockAdapter` for tests.
* **`MockAdapter`** — route-based mock transport with request capture.
* **Spec-driven endpoints** — author one `ApiSpec` and get:
  * a fully working `SpecMockAdapter` for tests (schema-validates request bodies),
  * an OpenAPI 3.1 document (`OpenApiGenerator.toJsonString()` / `toYaml()`),
  * a Markdown API reference (`MarkdownDocGenerator`),
  * a backend-implementation guide (`BackendGuideGenerator`) with route table,
    validation rules, status-code matrix, handler skeletons, and optional
    Express/FastAPI/Gin code snippets.
* **Real multi-request `CancelToken`** — one token cancels many requests
  without disturbing unrelated traffic.
* **`RetryInterceptor` + `RetryPolicy`** — exponential backoff, jitter,
  per-request override, and `Retry-After` header support.
* **Concurrent-safe `AuthInterceptor`** — 401 triggers exactly one refresh
  call; every concurrent request waits and is replayed.
* **`CacheInterceptor`** — `networkFirst`, `cacheFirst`, `staleWhileRevalidate`,
  `cacheOnly` modes with TTL and ETag/`If-None-Match` revalidation. Pluggable
  `CacheStore` with a built-in `MemoryCacheStore`.
* **`DedupInterceptor`** — coalesces in-flight identical GETs.
* **Logging interceptors** — `CurlLogger` (ready-to-paste cURL) and
  `PrettyLogger` (ANSI, header redaction).
* **`OfflineQueueInterceptor`** — persists failed mutations via a pluggable
  `OfflineQueueStore` for later replay.
* **Sealed `ApiResult<T>`** with `Success` / `Failure` and exhaustive `when`.
* **Generic `CustomApiResponse<T>`** with a `decoder` parameter on every verb.
* **Typed exceptions**: `NetworkError`, `TimeoutError`, `CancelError`,
  `HttpError`, `ParseError`, `UnknownError`.
* **`RequestOptions` upgraded** with `queryParameters`, `responseType`,
  `cancelToken`, `onSendProgress`, `onReceiveProgress`, and per-request
  retry/cache overrides.
* **Upload/download progress callbacks** via streamed requests/responses.
* **`FormData.fromMap`** helper for multipart uploads.
* **`buildQueryString` / `buildUri`** helpers with list & nested-map support.

### Fixed
* Cancelling a request no longer closes the shared global HTTP client and
  break unrelated in-flight requests. Each request now uses its own
  `http.Client`.
* Treats any `2xx` (not only 200/201/204) as success.

### Changed
* `ApiClient` verbs are now generic (`get<T>`, `post<T>`, …) with optional
  `decoder` and `T Function(Object json)?`.
* Interceptors are configured as a single ordered list
  (`ApiClientConfig(interceptors: [...])`). The legacy
  `requestInterceptor` / `responseInterceptor` fields were removed.

### Migration
* `await client.get('users')` ⇒ `await client.get<dynamic>('users')`.
* `final res = await client.get(...); if (res.isSuccess) ...` still works.
* For new code prefer `client.get<User>('users/me', decoder: (json) => User.fromJson(json as Map<String, dynamic>))`
  which returns `ApiResult<User>`.
* Replace single-interceptor config with the `interceptors:` list.

## 0.1.0

* Initial release with API client implementation.
* Support for GET, POST, PUT, PATCH, DELETE.
* Custom token storage and CachedTokenStorage for fast token access.
* Request/response interceptors.
* Per-request options (headers, timeout, base URL override).

## 0.0.1

* Initial scaffolding.
