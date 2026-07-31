# Architecture

This document describes the internal architecture of `flutter_api_client` to help contributors and maintainers understand how the package is structured.

## Design Principles

1. **Composability**: Features are modular and can be combined freely
2. **Type Safety**: Leverage Dart's type system for compile-time safety
3. **Zero Configuration**: Sensible defaults for common use cases
4. **Testability**: All components can be mocked and tested in isolation
5. **Extensibility**: Pluggable architecture for custom behavior

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        ApiClient                             │
│  • Typed HTTP methods (get, post, put, patch, delete)      │
│  • Request orchestration                                     │
│  • Result type conversion (`ApiResult<T>`)                  │
└────────────┬────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│                  InterceptorChain                            │
│  • Sequential request processing                             │
│  • Reverse-order response processing                         │
│  • Error propagation                                         │
└────────────┬────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│                    Interceptors                              │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐  │
│  │     Retry     │  │     Cache     │  │      Auth      │  │
│  │  Interceptor  │  │  Interceptor  │  │  Interceptor   │  │
│  └───────────────┘  └───────────────┘  └────────────────┘  │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐  │
│  │     Dedup     │  │    Offline    │  │    Logging     │  │
│  │  Interceptor  │  │     Queue     │  │  Interceptors  │  │
│  └───────────────┘  └───────────────┘  └────────────────┘  │
└────────────┬────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│                     HttpAdapter                              │
│  • Default: package:http                                     │
│  • Pluggable: cupertino_http, cronet_http                   │
│  • Test: MockAdapter                                         │
│  • Spec: SpecMockAdapter                                     │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. ApiClient (`lib/src/core/api_client.dart`)

The main entry point for making HTTP requests.

**Responsibilities:**
- Expose typed HTTP methods (`get<T>`, `post<T>`, etc.)
- Build complete URLs from base URL + endpoint
- Convert between `AdapterResponse` and public result types
- Manage global client state (base URL, headers, timeout)

**Key Methods:**

```dart
Future<ApiResult<T>> get<T>(String endpoint, {...})
Future<ApiResult<T>> post<T>(String endpoint, dynamic data, {...})
Future<ApiResult<T>> put<T>(String endpoint, dynamic data, {...})
Future<ApiResult<T>> patch<T>(String endpoint, dynamic data, {...})
Future<ApiResult<T>> delete<T>(String endpoint, {...})
```

**Design Decision**: One result type serves both common call sites and typed
error handling. `Success<T>` carries the decoded body, status code, and
headers. `Failure<T>` carries a typed `ApiException` with the optional HTTP
status code.

### 2. InterceptorChain (`lib/src/interceptors/interceptor_chain.dart`)

Manages the ordered execution of interceptors.

**Request Flow** (forward order):
```
AuthInterceptor → RetryInterceptor → CacheInterceptor → DedupInterceptor → Adapter
```

**Response Flow** (reverse order):
```
Adapter → DedupInterceptor → CacheInterceptor → RetryInterceptor → AuthInterceptor
```

**Control Flow Results:**
- `ProceedResult`: Continue to next interceptor
- `ResolveResult`: Short-circuit with success response
- `RejectResult`: Short-circuit with error

**Design Decision**: Reverse order on response ensures interceptors can handle their own modifications (e.g., cache writes, retry logic).

### 3. Interceptor Base (`lib/src/interceptors/interceptor.dart`)

Abstract base class for all interceptors.

**Hooks:**

```dart
abstract class Interceptor {
  Future<InterceptorResult> onRequest(InterceptedRequest req);
  Future<InterceptorResult> onResponse(InterceptedRequest req, AdapterResponse res);
  Future<InterceptorResult> onError(InterceptedRequest req, ApiException err);
}
```

**Design Decision**: Three separate hooks allow interceptors to act at different stages without complex conditional logic.

## Interceptor Details

### RetryInterceptor

**Location**: `lib/src/interceptors/retry/retry_interceptor.dart`

**Algorithm**: Exponential backoff with optional jitter

```
delay = min(baseDelay * 2^attempt + jitter, maxDelay)
```

**Retry Conditions**:
- Network errors on methods in `safeMethods`
- Timeout errors on methods in `safeMethods`
- Configurable HTTP status codes (default: 408, 429, 500-504) on methods in `safeMethods`

**Respect Retry-After**: Parses both delay-seconds and HTTP-date formats

**Design Decision**: Retries are opt-in for safe methods by default. Mutating requests are not retried unless the caller explicitly broadens `safeMethods`.

### CacheInterceptor

**Location**: `lib/src/interceptors/cache/cache_interceptor.dart`

**Cache Strategies**:

| Strategy | Behavior |
|----------|----------|
| `networkFirst` | Always hit network; cache is fallback |
| `cacheFirst` | Serve from cache if fresh; network on miss |
| `staleWhileRevalidate` | Serve fresh cache immediately; once stale, revalidate with the network before returning the refreshed response |
| `cacheOnly` | Never hit network; 504 on miss |

**ETag Flow**:
1. Store ETag from response
2. Add `If-None-Match` on next request
3. On 304, return cached entry

**Design Decision**: Cache key is `method:url`. Query params are part of URL, so different params = different cache entries.

**Design Decision**: The identity key (see `requestIdentityKey`) also includes the request headers — notably `Authorization`. Cached bodies must never leak across credentials, so a token refresh deliberately cold-starts the cache (and stops dedup coalescing) across the refresh boundary. The one-time re-fetch after a refresh is the accepted price of credential isolation.

### DedupInterceptor

**Location**: `lib/src/interceptors/dedup/dedup_interceptor.dart`

**Algorithm**:
1. On request, check if identical request is in-flight
2. If yes, wait for that request's future
3. If no, start new request and store future
4. On response/error, remove from in-flight map

**Key**: `method:url` (same as cache)

**Design Decision**: Only GETs are deduplicated by default. Mutations (POST, PUT, etc.) are not safe to deduplicate.

### AuthInterceptor

**Location**: `lib/src/auth/auth_interceptor.dart`

**Flow**:

```
1. onRequest: Inject Authorization header
2. onResponse: Check for 401
3. If 401:
   a. Acquire global refresh lock
   b. Call refreshToken()
   c. Update TokenStorage
   d. Release lock
   e. Replay original request
4. Other waiting requests see updated token
```

**Concurrent Safety**: Only one `refreshToken()` call happens even if 10 requests receive 401 simultaneously.

**Design Decision**: Global lock prevents token refresh race conditions and unnecessary refresh calls.

### OfflineQueueInterceptor

**Location**: `lib/src/interceptors/offline/offline_queue_interceptor.dart`

**Flow**:
1. On network/timeout error, check `isOnline()`
2. If offline and method is mutating (POST/PUT/PATCH/DELETE) and not
   multipart, enqueue (preserving query parameters and base-URL override;
   the `Authorization` header is stripped) and fire the optional `onQueued`
   callback
3. Later, app runs `OfflineQueueReplayer.replay()` to deliver the queue

**Persistence**: Implement `OfflineQueueStore` interface to persist queue across app restarts. Also implement `PeekableOfflineQueueStore` (both built-in stores do) to get crash-safe replay: requests stay persisted until each one is individually settled, instead of being destructively drained up front.

**Design Decision**: Read-only methods (GET, HEAD) are never enqueued because retrying them later may return different data. A store failure while enqueueing never masks the original network error. Overlapping `replay()` calls coalesce into a single pass so a chatty connectivity listener cannot double-send the queue.

### Logging Interceptors

**CurlLogger** (`lib/src/interceptors/logging/curl_logger.dart`):
- Outputs ready-to-paste `curl` commands
- Useful for debugging with real curl

**PrettyLogger** (`lib/src/interceptors/logging/pretty_logger.dart`):
- Structured console output with box-drawing characters
- Redacts sensitive headers by default

**Design Decision**: Two loggers serve different needs (quick copy-paste vs. readable console).

## Result Types

### ApiResult<T>

**Location**: `lib/src/core/api_result.dart`

Sealed result type returned by all HTTP verb methods:

```dart
sealed class ApiResult<T> {
  bool get isSuccess;
  bool get isFailure;
  T? get data;
  ApiException? get error;
  String? get errorMessage;
  int? get statusCode;
  Map<String, String> get headers;

  R when<R>({
    required R Function(T data) success,
    required R Function(ApiException error) failure,
  });
}
```

**Use Case**: One result model for both convenience checks and exhaustive
error handling.

### Parse behavior

For `ResponseType.json` responses:

- empty successful bodies decode to `null` when the requested `T` can represent `null`
- malformed successful JSON bodies raise `ParseError`
- obvious text / HTML successful bodies raise `ParseError`
- non-2xx responses remain `HttpError`, even if their body is malformed

## Exception Hierarchy

```
ApiException (sealed)
├── NetworkError        — DNS, connection failures
├── TimeoutError        — Request exceeded timeout
├── CancelError         — User cancelled via CancelToken
├── HttpError           — Non-2xx status codes
├── ParseError          — JSON decode failures
├── PayloadTooLargeError — Request/response body exceeds configured byte cap
└── UnknownError        — Catch-all for unexpected errors
```

**Design Decision**: Sealed exception class enables exhaustive `switch` statements for error handling.

## Spec System

The spec system generates multiple outputs from a single `ApiSpec` definition.

### ApiSpec

**Location**: `lib/src/spec/api_spec.dart`

**Components**:
- `EndpointSpec`: REST endpoints with method, path, schema, examples
- `GraphQLOperation`: GraphQL queries, mutations, subscriptions
- `Schema`: JSON Schema-like validation rules
- `ResponseExample`: Example responses with status codes

### Generators

**OpenApiGenerator** (`lib/src/spec/openapi_generator.dart`):
- Produces OpenAPI 3.1 YAML/JSON
- Compatible with Swagger UI, Postman, etc.

**MarkdownDocGenerator** (`lib/src/spec/markdown_doc_generator.dart`):
- Human-readable API reference
- Grouped by endpoint categories
- Includes request/response examples

**BackendGuideGenerator** (`lib/src/spec/backend_guide_generator.dart`):
- Implementation guide for backend developers
- Route tables, validation rules, handler skeletons
- Framework-specific snippets (Express, FastAPI, Gin)

**TestGenerator** (`lib/src/spec/test_generator.dart`):
- Complete runnable test suite
- Happy path, auth checks, error responses, schema validation

### SpecMockAdapter

**Location**: `lib/src/spec/spec_mock_adapter.dart`

**How It Works**:
1. Request arrives
2. Match against spec endpoints by pattern
3. Validate request body against `Schema`
4. Return declared `ResponseExample`
5. Support `statusOverrides` for error testing

**Design Decision**: Schema validation at mock level catches contract violations early in tests.

## GraphQL Support

### GraphQLClient

**Location**: `lib/src/graphql/graphql_client.dart`

Thin wrapper around `ApiClient` that implements GraphQL-over-HTTP protocol.

**Request Format**:
```json
{
  "query": "...",
  "variables": {...},
  "operationName": "..."
}
```

**Response Format**:
```json
{
  "data": {...},
  "errors": [{...}],
  "extensions": {...}
}
```

**APQ (Automatic Persisted Queries)**:
1. Send SHA-256 hash of query
2. On `PersistedQueryNotFound`, send full query
3. Server caches by hash for future requests

**Design Decision**: Reuses all `ApiClient` interceptors automatically (cache, retry, auth, etc.).

## Transport Layer

### HttpAdapter Interface

**Location**: `lib/src/http/http_adapter.dart`

```dart
abstract class HttpAdapter {
  Future<AdapterResponse> send(AdapterRequest request);
  void close();
}
```

**Design Decision**: Thin abstraction allows swapping HTTP implementation without changing any business logic.

### DefaultHttpAdapter

**Location**: `lib/src/http/default_http_adapter.dart`

Uses `package:http`:
- Creates one `http.Client` per request (prevents cancel side effects)
- Supports progress callbacks via streamed requests
- Handles multipart form data

### MockAdapter

**Location**: `lib/src/http/mock_adapter.dart`

Route-based mocking:

```dart
mock.on('GET', RegExp(r'/users$'), statusCode: 200, body: {...});
mock.onRequest('POST', RegExp(r'/login$'), (req) async {
  // Stateful/conditional responses
  return AdapterResponse(...);
});
```

**Design Decision**: Separate from `SpecMockAdapter` for fine-grained test control when you don't have a spec.

## Token Storage

### TokenStorage Interface

**Location**: `lib/src/auth/token_storage.dart`

```dart
abstract class TokenStorage {
  Future<String?> getAccessToken();
  Future<void> setAccessToken(String? token);
  Future<String?> getRefreshToken();
  Future<void> setRefreshToken(String? token);
  Future<void> clear();
}
```

**Implementations**:

**MemoryTokenStorage**: Volatile, for tests and simple apps

**CachedTokenStorage**: Wraps any `TokenStorage` with in-memory cache
- First read hits delegate (e.g., FlutterSecureStorage)
- Subsequent reads are synchronous from cache
- Writes update cache + delegate asynchronously

**Design Decision**: Cache layer dramatically improves performance when storage backend is slow (e.g., encrypted secure storage).

## Code Generation

### Build System

**ApiSpecBuilder** (`lib/src/gen/api_spec_builder.dart`):
- Scans for `@ApiSpecEntry()` annotations
- Generates `part` file with spec accessor
- Enables static access to spec from tests

### CLI Tool

**gen.dart** (`bin/gen.dart`):
- Discovers specs in project
- Generates OpenAPI, Markdown, backend guide, tests
- Flags: `--only` with any of `openapi`, `reference`, `backend`, `tests` (comma-separated), e.g. `--only tests` or `--only openapi,backend`

**Design Decision**: Separate CLI from build_runner allows on-demand doc generation without full rebuild.

## Testing Strategy

### Unit Tests

Each component has isolated unit tests:
- `test/api_result_test.dart`: Result type behavior
- `test/cache_interceptor_test.dart`: All cache strategies
- `test/retry_error_test.dart`: Retry conditions
- `test/mock_adapter_test.dart`: Routing and capture

### Integration Tests

Full stack tests with real interceptor chains:
- `test/mock_adapter_test.dart`: Multi-interceptor scenarios
- `test/spec_test.dart`: Spec → mock → request flow

### Coverage

Current: **374 tests, all passing**

Aim: >90% line coverage

**Design Decision**: Every public API has tests. Edge cases are covered when discovered via issues.

## Performance Considerations

### Memory

- **MemoryCacheStore**: Bounded LRU cache (default 256 entries)
- **DedupInterceptor**: In-flight map cleared on response/error
- **CachedTokenStorage**: Single token cached, not entire storage

### Network

- **Request dedup**: Prevents redundant network calls
- **Caching**: Reduces bandwidth and latency
- **ETag**: Conditional requests save bandwidth
- **APQ**: Reduces query payload size

### Concurrency

- **Auth refresh**: Single refresh call for concurrent 401s
- **Dedup**: Identical requests share one future
- **Http.Client**: One per request to avoid cancel side effects

## Versioning & Compatibility

**Semantic Versioning**: MAJOR.MINOR.PATCH

- **1.0.0**: Initial stable release
- **1.0.x**: Bug fixes, docs improvements
- **1.1.0**: Real streaming, offline-queue replay, hardened retries/cache/dedup (current)
- **1.x.x**: New features, backwards compatible
- **2.0.0**: Breaking changes

**Dart/Flutter Support**: SDK ≥3.0.0

**Design Decision**: Use stable features only; avoid experimental Dart features for maximum compatibility.

## Future Architecture Considerations

### Planned Enhancements

1. **WebSocket adapter**: Full-duplex communication
2. **Metrics**: Built-in telemetry (request counts, latency)
3. **Circuit breaker**: Fail-fast when backend is unhealthy
4. **Persistent cache**: SQLite/Hive backend for `CacheStore`

> Note: streaming downloads shipped in 1.1.0 via `ApiClient.stream()` /
> `HttpStreamResponse`; offline-queue replay shipped via `OfflineQueueReplayer`.

### Design Philosophy

- **Opt-in complexity**: Advanced features are optional
- **Interoperability**: Work with existing Flutter/Dart ecosystem
- **Documentation-first**: Every feature must have examples
- **Testing-first**: Tests before implementation

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Code style guidelines
- PR process
- Testing requirements
- Commit conventions

## Questions?

Open a [GitHub Discussion](https://github.com/dhirajnikam/flutter_api_client/discussions) or issue.
