# flutter_api_client

A type-safe, extensible HTTP client for Flutter/Dart. Ships with retries,
caching, request deduplication, concurrent-safe token refresh, an offline
write queue, structured logging, and a **spec-driven endpoint system** that
turns one `ApiSpec` into a working mock adapter, an OpenAPI 3.1 document,
a Markdown API reference, and a backend implementation guide.

[![pub package](https://img.shields.io/pub/v/flutter_api_client.svg)](https://pub.dev/packages/flutter_api_client)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-405%20passing-brightgreen)](#test-suite)

---

## Table of contents

1. [Why this package](#why-this-package)
2. [Installation](#installation)
3. [Quick start](#quick-start)
4. [ApiClient configuration](#apiclient-configuration)
5. [Making requests](#making-requests)
6. [Response types](#response-types)
7. [Error handling](#error-handling)
8. [Auth & token storage](#auth--token-storage)
9. [Interceptors](#interceptors)
   - [RetryInterceptor](#retryinterceptor)
   - [CacheInterceptor](#cacheinterceptor)
   - [DedupInterceptor](#dedupinterceptor)
   - [AuthInterceptor](#authinterceptor)
   - [OfflineQueueInterceptor](#offlinequeueinterceptor)
   - [CurlLogger](#curllogger)
   - [PrettyLogger](#prettylogger)
10. [Cancel tokens](#cancel-tokens)
11. [Multipart / file upload](#multipart--file-upload)
12. [GraphQL](#graphql)
13. [Spec-driven endpoints](#spec-driven-endpoints)
14. [Testing with MockAdapter](#testing-with-mockadapter)
15. [Pluggable transport](#pluggable-transport)
16. [API reference](#api-reference)
17. [Migration from 0.1.x](#migration-from-01x)
18. [Test suite](#test-suite)
19. [License](#license)

---

## Quick start — 3 steps

**1. Add the dependency**

```yaml
dependencies:
  flutter_api_client: ^1.4.0

dev_dependencies:
  build_runner: ^2.15.0
```

If you use the code generator, opt the builders into your project's
`build.yaml` (they no longer auto-apply to every consumer, so apps that only
use the runtime client don't pay the codegen/analyzer cost):

```yaml
# build.yaml
targets:
  $default:
    builders:
      flutter_api_client|api_spec_builder:
        enabled: true
      flutter_api_client|api_spec_test_builder:
        enabled: true
```

**2. Define your spec and generate files**

```dart
// lib/my_api.dart
import 'package:flutter_api_client/flutter_api_client.dart';
part 'my_api.g.dart';

@ApiSpecEntry()
final myApi = ApiSpec(
  title: 'My API',
  version: '1.0.0',
  baseUrl: 'https://api.example.com',
)..group('Users', (g) {
    g.endpoint('GET /users', responses: [ResponseExample.ok({'users': []})]);
  });
```

```bash
dart run build_runner build
# Generates:
#   lib/my_api.g.dart         — spec accessor
#   lib/my_api.test.g.dart    — runnable test scaffold
```

**3. Generate docs and a full test suite**

```bash
dart run flutter_api_client:gen
# Writes: docs/api/openapi.json, openapi.yaml, api-reference.md, backend-guide.md

dart run flutter_api_client:gen --only tests
# Writes: test/api_spec_test.dart  (complete runnable tests for every endpoint)

flutter test --concurrency=8
```

---

## Why this package

`flutter_api_client` is a production-ready HTTP client that goes beyond basic REST calls. It provides enterprise-grade features out of the box, eliminating the need for multiple third-party packages.

### Feature Comparison

| Feature | `dio` | `http` | `flutter_api_client` 1.1 |
|---|---|---|---|
| Typed `get<T>` / `post<T>` with decoder | manual | no | ✅ built-in |
| Sealed `ApiResult<T>` (Success / Failure) | no | no | ✅ built-in |
| Multi-request `CancelToken` | yes | no | ✅ yes |
| Exponential backoff + jitter + `Retry-After` | plugin | no | ✅ built-in |
| Concurrent-safe 401 refresh queue | DIY | no | ✅ built-in |
| Cache: `networkFirst`, `cacheFirst`, `staleWhileRevalidate`, `cacheOnly` | plugin | no | ✅ built-in |
| ETag / `If-None-Match` revalidation | plugin | no | ✅ built-in |
| Request dedup / in-flight coalescing | DIY | no | ✅ built-in |
| Offline write queue (pluggable storage) | DIY | no | ✅ built-in |
| cURL + pretty logger with redaction | plugin | no | ✅ built-in |
| Pluggable transport (`HttpAdapter`) | yes | no | ✅ yes |
| Built-in `MockAdapter` for tests | plugin | no | ✅ built-in |
| **Spec → mock + OpenAPI + docs + backend guide** | no | no | ✅ **yes** |
| Upload / download progress callbacks | yes | no | ✅ yes |
| Per-request response mode (JSON / bytes / text / stream) | yes | no | ✅ yes |
| GraphQL query / mutation / APQ | no | no | ✅ built-in |
| Zero native dependencies | yes | yes | ✅ yes |
| Production stability | mature | mature | ✅ stable |

### Key Advantages

1. **All-in-One Solution**: No need for `dio_smart_retry`, `dio_cache_interceptor`, `pretty_dio_logger`, `http_mock_adapter` — everything is integrated
2. **Spec-Driven Development**: Write your API contract once, get tests, docs, and backend guides automatically
3. **Type Safety**: Sealed `ApiResult<T>` ensures exhaustive error handling at compile time
4. **Zero Configuration for Common Patterns**: Sensible defaults for caching, retries, and auth refresh
5. **Testing First**: Built-in mocking without external dependencies
6. **GraphQL Support**: First-class query/mutation support with automatic persisted queries (APQ)

---

## Features at a Glance

### Core HTTP Client
- **Type-safe requests**: Generic methods `get<T>`, `post<T>`, `put<T>`, `patch<T>`, `delete<T>`
- **Sealed result type**: `ApiResult<T>` with exhaustive `Success` / `Failure` matching
- **Response modes**: JSON parsing, raw bytes, plain text, streaming
- **Custom decoders**: Transform responses directly to your model types
- **Multipart uploads**: File upload with progress tracking
- **Query parameters**: Automatic URL encoding with list and nested object support

### Authentication & Security
- **Token storage**: Pluggable `TokenStorage` interface with memory and cached implementations
- **Auto token refresh**: Concurrent-safe 401 handling with refresh queue
- **Header redaction**: Sensitive data protection in logs
- **Bearer token**: Automatic `Authorization` header injection
- **Per-request auth control**: Disable auth for public endpoints

### Resilience & Performance
- **Smart retries**: Exponential backoff with jitter and `Retry-After` header support
- **HTTP caching**: Four cache modes (`networkFirst`, `cacheFirst`, `staleWhileRevalidate`, `cacheOnly`)
- **ETag validation**: Automatic `If-None-Match` for bandwidth optimization
- **Request deduplication**: Collapse identical in-flight requests
- **Offline queue**: Persist failed writes for replay when online
- **Cancel tokens**: Cancel multiple related requests simultaneously
- **Payload size guards**: Optional request / response byte limits in the default adapter

### Developer Experience
- **Logging interceptors**: cURL commands and pretty-printed request/response logs
- **Custom interceptors**: Extensible request/response/error pipeline
- **Type-safe errors**: Seven typed exception classes for exhaustive error handling
- **Progress callbacks**: Track upload and download progress
- **Timeout control**: Per-request timeout overrides

### Testing & Mocking
- **MockAdapter**: Route-based mocking with request capture
- **SpecMockAdapter**: Schema-validating mock from API spec
- **Built-in test suite**: 405+ passing tests covering all features
- **No external mock libs**: Everything needed for testing included

### Spec-Driven Development (Unique Feature)
- **API specification DSL**: Define contracts with `ApiSpec`
- **OpenAPI generator**: Automatic OpenAPI 3.1 YAML/JSON output
- **Documentation generator**: Markdown API reference for developers
- **Backend guide generator**: Implementation guides for Express, FastAPI, Gin
- **Test generator**: Complete runnable test suites from specs
- **GraphQL support**: Query, mutation, subscription specs with SDL generation

### GraphQL Client
- **Query & mutation**: Full GraphQL-over-HTTP protocol support
- **Error handling**: Typed `GraphQLError` with location and path
- **Partial responses**: Handle mixed data and errors
- **Auto persisted queries (APQ)**: Bandwidth optimization with query hashing
- **Variable validation**: Schema-based variable checking in specs
- **Framework snippets**: backend skeletons for Express/Apollo, FastAPI/Strawberry, and Gin/gqlgen

### Extensibility
- **Pluggable transport**: Swap HTTP implementation (`cupertino_http`, `cronet_http`)
- **Custom adapters**: WebSocket, gRPC, or any custom transport
- **Interceptor chain**: Ordered execution with request/response/error hooks
- **Custom cache stores**: Implement persistent caching (SQLite, Hive, etc.)
- **Response handlers**: Custom error message extraction

---

## Installation

```yaml
# pubspec.yaml
dependencies:
  flutter_api_client: ^1.1.0
```

```bash
flutter pub get
```

**Runtime dependencies:** [`http`](https://pub.dev/packages/http) ^1.6.0,
[`collection`](https://pub.dev/packages/collection) ^1.19.1,
[`hive`](https://pub.dev/packages/hive) ^2.2.3.

**Permissions:** this package does not add Android, iOS, macOS, or web
permissions of its own. Outbound networking policy (for example Android
internet access or iOS/macOS App Transport Security exceptions) remains an
application-level concern.

---

## Quick start

```dart
import 'package:flutter_api_client/flutter_api_client.dart';

final client = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://api.example.com/api/v1',
    tokenStorage: MemoryTokenStorage(accessToken: 'my-jwt'),
    interceptors: [
      PrettyLogger(),
      DedupInterceptor(),
      CacheInterceptor(
        store: MemoryCacheStore(),
        defaultPolicy: CachePolicy.staleWhileRevalidate(Duration(minutes: 5)),
      ),
      RetryInterceptor(
        policy: RetryPolicy.exponential(maxAttempts: 3),
      ),
    ],
  ),
);

// Simple typed GET
final res = await client.get<Map<String, dynamic>>('users/me');
if (res.isSuccess) {
  print(res.data);           // Map<String, dynamic>
} else {
  print(res.errorMessage);   // human-readable string
}

// Typed result pattern (recommended for new code)
final result = await client.get<User>(
  'users/me',
  decoder: (json) => User.fromJson(json as Map<String, dynamic>),
);
result.when(
  success: (user) => print('Hello ${user.name}'),
  failure: (err)  => print('Error: ${err.message}'),
);
```

---

## ApiClient configuration

### `ApiClientConfig`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `baseUrl` | `String` | required | Base URL prepended to every endpoint |
| `tokenStorage` | `TokenStorage?` | — | Persistent token source (preferred) |
| `getAccessToken` | `Future<String?> Function()?` | — | Callback token source (alternative to `tokenStorage`) |
| `refreshToken` | `Future<bool> Function()?` | — | Called once on 401 before retry |
| `extraHeaders` | `Map<String, String>` | `{}` | Headers added to every request |
| `connectTimeout` | `Duration` | 30 s | Default request timeout |
| `authScheme` | `String` | `'Bearer'` | Prefix for `Authorization`; use `''` for a bare token |
| `maxRequestBodyBytes` | `int?` | `null` | Optional encoded request body limit for `DefaultHttpAdapter` |
| `maxResponseBodyBytes` | `int?` | `null` | Optional buffered response body limit for `DefaultHttpAdapter` |
| `responseHandler` | `ResponseHandlerInterface?` | built-in | Custom error-message extractor |
| `interceptors` | `List<Interceptor>` | `[]` | Applied in declaration order |
| `adapter` | `HttpAdapter?` | `DefaultHttpAdapter()` | Swap transport for tests or custom HTTP stacks |
| `defaultHeaders` | `Map<String, String>?` | `null` | Replaces the entire built-in default-header block when set |
| `defaultAccept` | `String` | `'application/json'` | Default `Accept` header |
| `defaultAcceptLanguage` | `String` | `'en'` | Default `Accept-Language` (locale) |
| `defaultContentType` | `String` | `'application/json'` | Default `Content-Type` for non-multipart requests |
| `authHeaderName` | `String` | `'Authorization'` | Header the auth token is written to |
| `bodySerializer` | `RequestBodySerializer` | JSON | Encodes request bodies before transport |
| `responseJsonCodec` | `ResponseJsonCodec` | `jsonDecode` | Parses JSON response bodies |
| `charset` | `Charset` | UTF-8 | Charset for encoding string bodies / decoding responses |
| `queryEncoder` | `QueryEncoder` | repeated-key | Serializes URL query parameters |
| `isSuccessStatus` | `bool Function(int)` | `2xx` | Decides which status codes are `Success` |

**Convenience constructors:**

```dart
// Token via callback
ApiClientConfig.withToken(
  baseUrl: 'https://api.example.com',
  getAccessToken: () async => await SecureStorage.read('token'),
  refreshToken:   () async => await authService.refresh(),
);

// Token via TokenStorage implementation
ApiClientConfig.withStorage(
  baseUrl:      'https://api.example.com',
  tokenStorage: CachedTokenStorage(MySecureStorage()),
  refreshToken: () async => await authService.refresh(),
);

// Swap transport in tests (no auth wired)
ApiClientConfig.test(
  baseUrl: 'https://api.example.com',
  adapter: MockAdapter(),
);

// Optional payload size limits (null = unlimited)
ApiClientConfig(
  baseUrl: 'https://api.example.com',
  maxRequestBodyBytes: 512 * 1024,
  maxResponseBodyBytes: 10 * 1024 * 1024,
);
```

### Deep customization

Every default is overridable, and every override is optional — leaving a knob
unset preserves the exact pre-1.3.0 behaviour.

**Default headers & locale**

```dart
ApiClientConfig(
  baseUrl: 'https://api.example.com',
  defaultAcceptLanguage: 'fr-CA',                 // locale
  defaultAccept: 'application/vnd.api+json',
  defaultContentType: 'application/json; charset=utf-8',
);

// …or replace the built-in Accept / Accept-Language / Content-Type block wholesale:
ApiClientConfig(
  baseUrl: 'https://api.example.com',
  defaultHeaders: {'Accept': 'application/cbor', 'X-App': 'myapp'},
);
```

Per-request `headers` / `extraHeaders` still override these case-insensitively.

**Pluggable serialization** — implement `RequestBodySerializer`,
`ResponseJsonCodec`, and/or `Charset` to send/parse a non-JSON or non-UTF-8
payload. `Charset.decode` and `ResponseJsonCodec.decode` must throw a
`FormatException` on bad input so the client can surface a typed `ParseError`.

```dart
class FormUrlEncodedSerializer implements RequestBodySerializer {
  const FormUrlEncodedSerializer();
  @override
  Object? encode(Object? data) => data is Map
      ? data.entries
          .map((e) => '${Uri.encodeQueryComponent('${e.key}')}='
              '${Uri.encodeQueryComponent('${e.value}')}')
          .join('&')
      : data?.toString();
}

ApiClientConfig(
  baseUrl: 'https://api.example.com',
  bodySerializer: const FormUrlEncodedSerializer(),
);
```

**Query-string encoding** — control how lists, nested maps, and nulls render:

```dart
ApiClientConfig(
  baseUrl: 'https://api.example.com',
  queryEncoder: const QueryEncoder(
    listFormat: QueryListFormat.comma,   // ids=1,2,3  (also: repeated | brackets)
    nested: QueryNestedStyle.dotted,     // filter.name=foo  (or: brackets)
    includeNulls: true,                  // emit q=  instead of dropping nulls
  ),
);
```

**Retry backoff / auth header / success boundary**

```dart
// A custom backoff curve (still capped at maxDelay, jittered when enabled):
RetryInterceptor(
  policy: RetryPolicy(backoff: (attempt) => Duration(seconds: attempt * attempt)),
);

// A non-standard auth header, and a custom success rule (treat 3xx as success):
ApiClientConfig(
  baseUrl: 'https://api.example.com',
  authHeaderName: 'X-Auth-Token',
  isSuccessStatus: (code) => code >= 200 && code < 400,
);
```

> **Note:** if you rename the auth header, the bundled loggers won't redact it
> by default (they key on `authorization`). Add your header name to the
> logger's `redactHeaders` set so the token isn't logged in the clear.

**Through the convenience factories** — `withToken` / `withStorage` / `test`
accept a single `ClientCustomization` bundle so you don't need the full
constructor:

```dart
ApiClientConfig.withToken(
  baseUrl: 'https://api.example.com',
  getAccessToken: () async => await SecureStorage.read('token'),
  customization: const ClientCustomization(
    defaultAcceptLanguage: 'de-DE',
    authHeaderName: 'X-Auth-Token',
  ),
);
```

---

## Making requests

Every verb method accepts an optional `RequestOptions` to override
config-level settings for a single call.

```dart
// GET
final res = await client.get<List<dynamic>>('posts');

// POST with body
final res = await client.post<Map<String, dynamic>>(
  'posts',
  {'title': 'Hello', 'body': 'World'},
);

// PUT / PATCH / DELETE
await client.put('posts/1',   {'title': 'Updated'});
await client.patch('posts/1', {'title': 'Patched'});
await client.delete('posts/1');

// QUERY — safe, idempotent, cacheable read that carries a request body, so
// complex queries live in the body instead of the URL. Standardized in
// RFC 10008: https://www.rfc-editor.org/rfc/rfc10008.html
final res = await client.query<List<dynamic>>(
  'posts/search',
  {'filter': {'author': 'ada'}, 'sort': 'created_at'},
);

// Per-request options
final res = await client.get<dynamic>(
  'feed',
  options: RequestOptions(
    queryParameters: {'page': 2, 'limit': 20},
    timeout:         Duration(seconds: 10),
    baseUrlOverride: 'https://cdn.example.com',
    includeToken:    false,
    extraHeaders:    {'X-Client-Version': '3.0'},
    responseType:    ResponseType.json,
    cancelToken:     myToken,
    cachePolicy:        CachePolicy.networkFirst(),
    retryPolicy:        RetryPolicy(maxAttempts: 1),
    maxRequestBodyBytes: 64 * 1024,
    maxResponseBodyBytes: 512 * 1024,
    onReceiveProgress:  (received, total) => print('$received/$total'),
  ),
);
```

### Payload size limits

`DefaultHttpAdapter` can enforce optional encoded request and buffered response
body limits. Both limits default to `null`, which preserves the current
unlimited behavior.

If a configured limit is exceeded, the request fails with
`PayloadTooLargeError`.

```dart
final client = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://api.example.com',
    maxRequestBodyBytes: 512 * 1024,
    maxResponseBodyBytes: 10 * 1024 * 1024,
  ),
);

final result = await client.get<dynamic>(
  'feed',
  options: const RequestOptions(maxResponseBodyBytes: 256 * 1024),
);
```

Custom adapters may ignore these limits unless they implement the same policy.

---

### Decoder

A `decoder` maps raw JSON directly to your model type:

```dart
final res = await client.get<User>(
  'users/me',
  decoder: (json) => User.fromJson(json as Map<String, dynamic>),
);
```

---

## Response types

### `ApiResult<T>` — returned by all verb methods

All HTTP verb methods (`get`, `post`, `put`, `patch`, `delete`) return the same
sealed result type:

```dart
final result = await client.get<User>(
  'users/me',
  decoder: (json) => User.fromJson(json as Map<String, dynamic>),
);

result.when(
  success: (user) => print(user.name),
  failure: (err) => print(err.message),
);

// Convenience helpers
result.isSuccess   // bool
result.isFailure   // bool
result.data        // T?
result.error       // ApiException?
result.errorMessage // String?
result.statusCode  // int?
result.headers     // Map<String, String>

// Transform the success value without unwrapping
final nameResult = result.map((user) => user.name); // ApiResult<String>
```

`ParseError` is used when a successful `ResponseType.json` response contains
malformed JSON or an obvious text / HTML payload. Empty successful JSON bodies
decode to `null` when the requested `T` can represent `null`.

### Response body modes (`ResponseType`)

| Mode | Returns | Use for |
|---|---|---|
| `json` (default) | parsed `dynamic` / decoded `T` | JSON APIs |
| `bytes` | `Uint8List` | images, binary downloads |
| `plainText` | `String` (UTF-8, no JSON parse) | plain-text health endpoints |
| `stream` | `Uint8List` (buffered) | advanced use |

```dart
// Raw bytes
final res = await client.get<Uint8List>('photo.png',
    options: RequestOptions(responseType: ResponseType.bytes));

// Plain text
final res = await client.get<String>('health',
    options: RequestOptions(responseType: ResponseType.plainText));
```

---

## Error handling

All exceptions from `ApiClient` derive from the sealed `ApiException`:

| Subtype | When raised |
|---|---|
| `NetworkError` | DNS, socket, or connectivity failure |
| `TimeoutError` | Request exceeded its timeout |
| `CancelError` | Cancelled via `CancelToken.cancel()` |
| `PayloadTooLargeError` | Configured request or response byte limit was exceeded |
| `HttpError` | Non-2xx response (carries `statusCode`, `body`, `headers`) |
| `ParseError` | Response body could not be decoded |
| `UnknownError` | Any other unexpected exception |

`Failure` carries a typed `ApiException`, so exhaustive matching is possible:

```dart
final result = await client.get<dynamic>('users/1');
if (result case Failure(:final error)) {
  switch (error) {
    case NetworkError(:final message):
      showOfflineBanner(message);
    case HttpError(:final statusCode) when statusCode == 401:
      navigateToLogin();
    case TimeoutError():
      showRetryDialog();
    case ParseError():
      showUnexpectedPayloadDialog();
    default:
      logError(error);
  }
}
```

---

## Auth & token storage

### `TokenStorage` interface

Implement this to integrate any persistence layer:

```dart
class SecureTokenStorage implements TokenStorage {
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> getAccessToken() =>
      _storage.read(key: 'access_token');

  @override
  Future<void> setAccessToken(String? token) =>
      _storage.write(key: 'access_token', value: token);

  @override
  Future<String?> getRefreshToken() =>
      _storage.read(key: 'refresh_token');

  @override
  Future<void> setRefreshToken(String? token) =>
      _storage.write(key: 'refresh_token', value: token);
}
```

`TokenStorage.clear()` is provided by default and calls both setters with `null`.

### `MemoryTokenStorage`

Volatile in-memory storage — good for tests and simple apps:

```dart
MemoryTokenStorage(accessToken: 'jwt', refreshToken: 'refresh-jwt')
```

### `CachedTokenStorage`

Wraps any `TokenStorage` with an in-memory layer so `getAccessToken()`
is synchronously fast after the first read. Writes update the cache
immediately and persist to the delegate in the background:

```dart
final storage = CachedTokenStorage(SecureTokenStorage());

// Force the next read to hit the delegate again (e.g., after logout elsewhere)
storage.clearCache();

// Update cache + delegate immediately
storage.updateAccessToken('new-jwt');
storage.updateRefreshToken('new-refresh-jwt');
```

### Concurrent-safe 401 refresh

When multiple requests simultaneously receive `401`, exactly **one**
`refreshToken` call is made. All other requests wait on the same future
and replay with the new token automatically:

```dart
ApiClientConfig(
  baseUrl: 'https://api.example.com',
  tokenStorage: CachedTokenStorage(SecureTokenStorage()),
  refreshToken: () async {
    final newToken = await authService.refresh(); // called exactly once
    return newToken != null;
  },
)
```

---

## Interceptors

Pass interceptors to `ApiClientConfig.interceptors`. They run in
**list order on request** and **reverse list order on response/error**.

> **Recommended ordering:** place `DedupInterceptor` **before** `RetryInterceptor`
> in the list (e.g. `[DedupInterceptor(), RetryInterceptor(), CacheInterceptor(...)]`
> — auth is prepended automatically). Either order is *correct*, but with dedup
> ahead of retry the dedup window spans the whole retry sequence, so followers
> coalesce onto the retried result (fewer network hits). With retry ahead of
> dedup, followers are released on the pre-retry failure and re-issue
> independently (still correct, just more network hits).

Each interceptor overrides one or more of:

```dart
Future<InterceptorResult> onRequest(InterceptedRequest req)  → ProceedResult / ResolveResult / RejectResult
Future<InterceptorResult> onResponse(InterceptedRequest, AdapterResponse) → same
Future<InterceptorResult> onError(InterceptedRequest, ApiException)       → same
```

---

### `RetryInterceptor`

Retries retryable transport failures and retryable status responses with
exponential backoff, optional jitter, and `Retry-After` header support.

```dart
RetryInterceptor(
  policy: RetryPolicy(
    maxAttempts:     3,                         // total attempts (initial + retries)
    baseDelay:       Duration(milliseconds: 200),
    maxDelay:        Duration(seconds: 30),
    retryOnStatus:   {408, 429, 500, 502, 503, 504},
    safeMethods:     {'GET', 'HEAD', 'OPTIONS'},
    useJitter:       true,   // randomises delay ±30%
    respectRetryAfter: true, // honours Retry-After response header
  ),
)

// Convenience factory
RetryInterceptor(policy: RetryPolicy.exponential(maxAttempts: 4))
```

**Triggers a retry:**
- Status codes in `retryOnStatus` on methods in `safeMethods`
- `NetworkError` or `TimeoutError` on methods in `safeMethods`

**Does not trigger a retry:**
- Non-safe methods unless you explicitly include them in `safeMethods`
- 4xx errors other than 408 / 429
- `HttpError` with any other code
- `CancelError`

**Per-request override:**

```dart
await client.get('resource',
  options: RequestOptions(retryPolicy: RetryPolicy(maxAttempts: 1)));
```

---

### `CacheInterceptor`

Caches GET responses in a `CacheStore`. `MemoryCacheStore` is a bounded
LRU cache (default 256 entries). For on-disk persistence implement the
`CacheStore` interface backed by Hive, SQLite, etc.

**Cache modes:**

| Mode | Behaviour |
|---|---|
| `cacheFirst` | Serve from cache if fresh. Fall back to network; update cache. |
| `networkFirst` | Always hit network first; update cache on 2xx. Return stale cache only if network fails. |
| `staleWhileRevalidate` | If a cached entry exists and TTL is still valid, return it immediately. Once the TTL has expired, the interceptor performs a conditional network revalidation before serving the new response. |
| `cacheOnly` | Only serve from cache. Returns status 504 on a cache miss. |

```dart
CacheInterceptor(
  store: MemoryCacheStore(maxEntries: 500),
  defaultPolicy: CachePolicy.cacheFirst(ttl: Duration(minutes: 10)),
)
```

**ETag / `If-None-Match`:** enabled by default. On subsequent requests the
interceptor adds `If-None-Match` with the stored ETag. A 304 response is
transparently converted to the cached entry.

**Per-request override:**

```dart
// Force fresh data for one call
await client.get('live-price',
    options: RequestOptions(cachePolicy: CachePolicy.networkFirst()));

// Offline read-only
await client.get('config',
    options: RequestOptions(cachePolicy: CachePolicy.cacheOnly()));
```

**Custom persistent store:**

```dart
class HiveCacheStore implements CacheStore {
  @override Future<CacheEntry?> read(String key)        async { ... }
  @override Future<void>        write(CacheEntry entry) async { ... }
  @override Future<void>        delete(String key)      async { ... }
  @override Future<void>        clear()                 async { ... }
}
```

---

### `DedupInterceptor`

Coalesces identical in-flight requests so the network is only hit once.
All callers that issued the same method + URL while the first request was
in-flight receive the identical `AdapterResponse` object.

```dart
DedupInterceptor()                                    // GET + HEAD (default)
DedupInterceptor(methods: {'GET', 'HEAD', 'OPTIONS'}) // custom set
```

Useful when multiple widgets independently trigger the same endpoint on the
same frame (e.g., a user avatar fetched by both the app bar and a profile card).

---

### `AuthInterceptor`

Attaches the `Authorization` header and handles 401 token refresh.
**Normally added automatically** when you set `tokenStorage` or
`getAccessToken` on the config. Add it manually only if you need a custom
`retryStatusCodes` set:

```dart
AuthInterceptor(
  storage:          CachedTokenStorage(SecureTokenStorage()),
  refresh:          () async => await authService.refresh(),
  authScheme:       'Bearer',  // default; '' for bare token
  retryStatusCodes: {401},     // default
)
```

**`includeToken: false`:** no `Authorization` header is attached, and 401
retry is skipped. Use for public endpoints such as login.

**Empty/null token:** no `Authorization` header is added — no crash.

---

### `OfflineQueueInterceptor`

Captures mutating requests that fail with `NetworkError` or `TimeoutError`
while the device is offline and stores them for later replay.

```dart
final box = await Hive.openBox<String>('offline_queue');

OfflineQueueInterceptor(
  store:    HiveOfflineQueueStore(box),
  isOnline: () async => (await Connectivity().checkConnectivity())
                        != ConnectivityResult.none,
  methods:  {'POST', 'PUT', 'PATCH', 'DELETE'}, // default
  onQueued: (queued) => showSnackBar('Saved offline — will sync'), // optional
)
```

Queued records preserve the request's query parameters and base-URL override,
so replay targets exactly the URL the original request did. The optional
`onQueued` callback fires after a request lands in the queue — use it for
"saved offline" UI or to schedule a replay pass.

**Replaying the queue** when connectivity returns — use the built-in
`OfflineQueueReplayer`:

```dart
final box = await Hive.openBox<String>('offline_queue');
final store = HiveOfflineQueueStore(box);

// ...when online (e.g. from a connectivity listener):
final report = await OfflineQueueReplayer(
  store: store,
  client: client,
  maxAttempts: 3, // dead-letter a request after this many failed replays
  onDeadLetter: (queued, error) => // optional: a queued write was dropped
      log('dropped ${queued.method} ${queued.endpoint}: $error'),
).replay();

print(report); // succeeded / reEnqueued / deadLettered counts
```

The replayer processes the queue in `createdAt` order and re-issues each
request through `client`, so a fresh `Authorization` token is attached
automatically. A request that fails transiently (network/timeout) is
re-enqueued with an incremented attempt count; once it reaches `maxAttempts`
it is dead-lettered instead of looping forever. A request the server actually
rejects (a non network/timeout error) is dropped, and the optional
`onDeadLetter` callback tells you about every drop.

Replay is crash-safe with the built-in stores: they implement
`PeekableOfflineQueueStore`, so requests stay persisted until each one is
individually settled — a crash mid-replay cannot lose the not-yet-sent tail.
(Delivery is at-least-once: a crash between a send and its removal replays
that one request again on the next pass.) Custom stores that only implement
`OfflineQueueStore` keep the original drain-based behaviour; implement
`peekAll()` to opt into crash-safe replay. Overlapping `replay()` calls are
coalesced into a single pass, so wiring it to a chatty connectivity listener
cannot double-send the queue.

Queued requests retain ordinary request headers, but the interceptor drops the
`Authorization` header before persisting so replay uses the current token
instead of a stale one.

**Never enqueued:**
- GET / HEAD (idempotent reads)
- `HttpError` (4xx/5xx — server-side, not a connectivity issue)
- Requests when `isOnline()` returns `true`
- Multipart uploads (file/stream payloads cannot be persisted and replayed
  faithfully)

If the store itself fails to persist a request (e.g. the body is not
JSON-serialisable, or the disk write throws), the original network error is
still what the caller sees — a queueing failure never masks it.

`HiveOfflineQueueStore` is the built-in persistent option. It stores each
queued request as a JSON string in a user-supplied `Hive` box. Queue bodies
must remain JSON-serialisable to persist cleanly.

---

### `CurlLogger`

Logs every request as a ready-to-paste `curl` command. Sensitive headers and
common credential keys in JSON request bodies are redacted by default.

```dart
CurlLogger(
  printer:       (s) => debugPrint(s),
  redactHeaders: const {'authorization', 'x-api-key'},
)
```

**Example output:**

```
curl -X POST -H 'Content-Type: application/json' \
  -H 'Authorization: <redacted>' \
  --data '{"email":"a@b.com","password":"<redacted>"}' \
  'https://api.example.com/api/v1/auth/login'
```

---

### `PrettyLogger`

Structured, colour-coded request/response logger. Sensitive response headers
are redacted, and response bodies are capped at 2 000 characters (truncated
with `…`).

```dart
PrettyLogger(
  printer:       (s) => debugPrint(s),
  redactHeaders: const {'authorization', 'cookie', 'set-cookie'},
  requestBody:   true,
  responseBody:  true,
  useColors:     true,  // set false in CI / log files
)
```

**Example output:**

```
┌─── POST auth/login ───
│ Content-Type: application/json
│ Authorization: <redacted>
│ body: {"email":"a@b.com","password":"<redacted>"}
└───────────────
┌─── 200 POST auth/login ───
│ content-type: application/json
│ set-cookie: <redacted>
│ body: {"token":"<redacted>","user":{"id":1}}
└───────────────
```

---

## Cancel tokens

A single `CancelToken` can be bound to multiple requests. `cancel()` causes
every associated request to complete with `CancelError` without disturbing
unrelated ones. With the default `DefaultHttpAdapter`, request-owned
`package:http` clients are also closed on cancel; shared injected clients are
not.

```dart
final token = CancelToken();

// Bind to multiple requests
final [feed, comments] = await Future.wait([
  client.get('feed',     options: RequestOptions(cancelToken: token)),
  client.get('comments', options: RequestOptions(cancelToken: token)),
]);

// Cancel both when the user navigates away
token.cancel('screen closed');

// State inspection
token.isCancelled          // true
token.error                // CancelError('screen closed')
token.whenCancelled        // Future<CancelError>

// Guard code that runs after async gaps
token.throwIfCancelled();  // throws CancelError if already cancelled

// Listener (returns unregister function)
final unregister = token.addListener((err) {
  print('Cancelled: ${err.message}');
});
unregister(); // stop listening before cancel fires

// A listener registered after cancel fires immediately
final afterToken = CancelToken()..cancel('already done');
afterToken.addListener((err) => print(err.message)); // fires synchronously
```

---

## Multipart / file upload

```dart
import 'package:http/http.dart' as http;

final avatar = await http.MultipartFile.fromPath('avatar', '/path/to/photo.jpg');

final res = await client.post<Map<String, dynamic>>(
  'users/me/avatar',
  FormData.fromMap({
    'avatar':      avatar,
    'description': 'Profile picture',
    'tags':        ['selfie', 'profile'],   // → repeated fields tags[]
  }),
  isMultipart: true,
  options: RequestOptions(
    onSendProgress: (sent, total) =>
        print('${(sent / total! * 100).round()}%'),
  ),
);
```

`FormData.fromMap` type handling:

| Value type | Result |
|---|---|
| `String` / `num` / `bool` | Form field (toString'd) |
| `http.MultipartFile` | File part |
| `List<http.MultipartFile>` | Multiple file parts |
| `List<T>` | Repeated fields as `key[]` |
| `null` | Skipped |

---

## GraphQL

`GraphQLClient` wraps an `ApiClient` and implements the standard
GraphQL-over-HTTP protocol (`{query, variables, operationName}` →
`{data, errors, extensions}`).

```dart
final gql = GraphQLClient(client, endpoint: '/graphql');
```

### Query

```dart
final res = await gql.query<User>(
  r'query Me { me { id name email } }',
  decoder: (data) => User.fromJson((data as Map)['me']),
);

if (res.isSuccess) {
  print(res.data!.name);
} else if (res.hasErrors) {
  for (final e in res.errors) {
    // e.message, e.locations, e.path, e.extensions
    print('[${e.extensions?["code"]}] ${e.message}');
  }
}
```

### Mutation

```dart
final res = await gql.mutation<Map<String, dynamic>>(
  r'''
    mutation Login($email: String!, $password: String!) {
      login(email: $email, password: $password) { token }
    }
  ''',
  variables:    {'email': 'a@b.com', 'password': 'secret123'},
  includeToken: false,
);
```

### `GraphQLResponse<T>` fields

| Field | Type | Description |
|---|---|---|
| `data` | `T?` | Decoded `data` field |
| `errors` | `List<GraphQLError>` | Empty on full success |
| `isSuccess` | `bool` | True only when `errors` is empty and no transport error |
| `isPartial` | `bool` | True when both `data` and `errors` are present |
| `hasErrors` | `bool` | Shorthand for `errors.isNotEmpty` |
| `statusCode` | `int` | Underlying HTTP status |
| `networkError` | `ApiException?` | Set when transport failed entirely |
| `extensions` | `Map<String, Object?>?` | Server metadata block |

### Automatic Persisted Queries (APQ)

```dart
final gql = GraphQLClient(
  client,
  usePersistedQueries: true,
);
```

On first send the client transmits only the hash. On `PersistedQueryNotFound`
it automatically falls back to the full document. The default hash is the
SHA-256 hex digest the APQ protocol expects, so it matches a server-registered
document out of the box — override `hashQuery` only for a custom registry.

All `ApiClient` interceptors apply to GraphQL calls transparently because
every operation routes through the standard HTTP layer.

---

## Spec-driven endpoints

`ApiSpec` is the single source of truth for your API contract. One spec drives:

1. A `SpecMockAdapter` — full integration tests with no real server
2. OpenAPI 3.1 YAML — for tooling and codegen
3. Markdown API reference — for frontend developers
4. A backend implementation guide — for your server team

### Defining a spec

```dart
final spec = ApiSpec(
  title:   'My App API',
  version: '1.0.0',
  baseUrl: 'https://api.example.com/api/v1',
);

spec.group('Auth', (g) {
  g.endpoint(
    'POST /auth/login',
    summary: 'Authenticate with email + password',
    auth: false,
    request: RequestExample(
      body: const {'email': 'a@b.com', 'password': 'secret123'},
      schema: Schema.object({
        'email':    Schema.string(format: 'email', required: true),
        'password': Schema.string(minLength: 8,    required: true),
      }),
    ),
    responses: [
      ResponseExample.ok(const {'token': 'jwt', 'user': {'id': 1}}),
      ResponseExample.error(401, const {'message': 'Invalid credentials'}),
    ],
  );
});

spec.group('Users', (g) {
  g.endpoint(
    'GET /users/{id}',
    summary:    'Fetch a user by ID',
    pathParams: {'id': Schema.integer(required: true)},
    response:   ResponseExample.ok(const {'id': 1, 'name': 'Alice'}),
  );
});
```

### GraphQL in the same spec

```dart
spec.graphql((g) {
  g.query(
    'Me',
    document:        r'query Me { me { id name } }',
    responseExample: const {'me': {'id': 1, 'name': 'Alice'}},
  );
  g.mutation(
    'Login',
    document: r'''
      mutation Login($email: String!, $password: String!) {
        login(email: $email, password: $password) { token }
      }
    ''',
    variables: {
      'email':    Schema.string(required: true, format: 'email'),
      'password': Schema.string(required: true, minLength: 8),
    },
    responseExample: const {'login': {'token': 'jwt'}},
    errors: const [
      GraphQLErrorExample(
        message:    'Invalid credentials',
        extensions: {'code': 'UNAUTHENTICATED'},
      ),
    ],
  );
});
```

### Using the spec as a mock in tests

`SpecMockAdapter` validates request bodies against their declared `Schema`
and returns the declared response example. No real server required.

```dart
final client = ApiClient(
  ApiClientConfig.test(
    baseUrl: spec.baseUrl,
    adapter: SpecMockAdapter(spec),
  ),
);

// Valid request → 200 with declared response body
final ok = await client.post('auth/login',
    const {'email': 'a@b.com', 'password': 'secret123'},
    includeToken: false);
expect(ok.isSuccess, true);
expect(ok.data, contains('token'));

// Invalid body (password too short) → 422 Unprocessable Entity
final bad = await client.post('auth/login',
    const {'email': 'a@b.com', 'password': 'x'},
    includeToken: false);
expect(bad.statusCode, 422);

// Force a specific error in one test
final forcedError = ApiClient(ApiClientConfig.test(
  baseUrl: spec.baseUrl,
  adapter: SpecMockAdapter(spec,
    statusOverrides: {'POST /auth/login': 401}),
));

// Force a GraphQL error
final gqlError = ApiClient(ApiClientConfig.test(
  baseUrl: spec.baseUrl,
  adapter: SpecMockAdapter(spec,
    statusOverrides: {'GQL Login': 401}),
));
```

### Generating OpenAPI, docs, and backend guide

```dart
import 'dart:io';
import 'package:flutter_api_client/flutter_api_client.dart';

void main() {
  final spec = buildSpec();
  Directory('doc').createSync(recursive: true);

  File('doc/openapi.yaml')
      .writeAsStringSync(OpenApiGenerator(spec).toYaml());

  File('doc/API_DOCS.md')
      .writeAsStringSync(MarkdownDocGenerator(spec).generate());

  File('doc/BACKEND_GUIDE.md').writeAsStringSync(
    BackendGuideGenerator(
      spec,
      framework: BackendFramework.express, // .express / .fastapi / .gin
    ).generate(),
  );
}
```

The backend guide contains:
- Architecture diagram and route table
- Auth notes, standard error envelope, status-code matrix
- Per-endpoint validation rules, sample request/response bodies, handler skeletons
- **GraphQL section:** operation table, derived SDL with auto-generated types, resolver skeletons, framework snippets
- Acceptance checklist (REST + GraphQL) for your backend developers

### Schema types

```dart
Schema.string(format: 'email', required: true, minLength: 5, maxLength: 255)
Schema.integer(required: true, minimum: 1, maximum: 9999)
Schema.number(minimum: 0.0)
Schema.boolean()
Schema.array(Schema.string())
Schema.object({
  'name': Schema.string(required: true),
  'age':  Schema.integer(),
})
```

---

## Testing with MockAdapter

`MockAdapter` records all received requests and returns canned responses.

```dart
final mock = MockAdapter();

// Static route
mock.on('GET', RegExp(r'/users/1$'),
    statusCode: 200, body: {'id': 1, 'name': 'Alice'});

// Dynamic route — for stateful / conditional responses
var calls = 0;
mock.onRequest('GET', RegExp(r'/flaky$'), (req) async {
  calls++;
  if (calls < 3) throw const NetworkError('down');
  return AdapterResponse(
    statusCode: 200,
    headers:   const {},
    bodyBytes: Uint8List.fromList('{"ok":true}'.codeUnits),
  );
});

final client = ApiClient(
  ApiClientConfig.test(
    baseUrl: 'https://api.example.com',
    adapter: mock,
  ),
);

// Assert captured requests
expect(mock.received, hasLength(1));
expect(mock.received.first.method, 'GET');
expect(mock.received.first.headers['Authorization'], isNotNull);
```

Returns 404 automatically for any unregistered route. Add a `latency`
parameter to simulate network delay:

```dart
MockAdapter(latency: Duration(milliseconds: 50))
```

---

## Pluggable transport

Swap the underlying HTTP implementation without touching any other code:

```dart
// Default: package:http
ApiClientConfig(baseUrl: '...')

// Custom client factory (e.g. cupertino_http, cronet_http)
ApiClientConfig(
  baseUrl: '...',
  adapter: DefaultHttpAdapter(
    clientFactory: () => CupertinoClient.defaultSessionConfiguration(),
  ),
)

// Fully custom adapter (WebSocket bridge, gRPC, etc.)
class MyAdapter implements HttpAdapter {
  @override
  Future<AdapterResponse> send(AdapterRequest request) async { ... }
  @override
  void close() {}
}
```

**`AdapterRequest` carries:**
`method`, `url`, `headers`, `body`, `formData`, `isMultipart`, `timeout`,
`cancelToken`, `onSendProgress`, `onReceiveProgress`

**`AdapterResponse` carries:**
`statusCode`, `headers`, `bodyBytes`, `reasonPhrase`

---

## API reference

### Core

| Symbol | Description |
|---|---|
| `ApiClient` | Main HTTP client |
| `ApiClientConfig` | Configuration value object |
| `ApiClientInterface` | Abstract contract for `get/post/put/patch/delete` |
| `ApiResult<T>` | Sealed result returned by all HTTP verb methods |
| `Success<T>` | Successful `ApiResult` (carries `data`, `statusCode`, `headers`) |
| `Failure<T>` | Failed `ApiResult` (carries `error`, optional `statusCode`) |
| `ApiException` | Sealed base class for all errors |
| `NetworkError` | I/O / connectivity failure |
| `TimeoutError` | Request timed out |
| `CancelError` | Cancelled via `CancelToken` |
| `PayloadTooLargeError` | Configured payload byte limit exceeded |
| `HttpError` | Non-2xx HTTP status (carries `statusCode`, `body`, `headers`) |
| `ParseError` | Response body decode failure |
| `UnknownError` | Catch-all |
| `CancelToken` | Cancel one or more in-flight requests |
| `RequestOptions` | Per-request config overrides |
| `ResponseType` | `json` / `bytes` / `plainText` / `stream` |
| `FormData` | Multipart form data builder |
| `buildUri()` | Constructs `Uri` from base URL + endpoint + query params |
| `buildQueryString()` | Encodes a `Map<String, dynamic>` to a query string |

### Auth

| Symbol | Description |
|---|---|
| `TokenStorage` | Abstract interface (implement to plug in any backend) |
| `MemoryTokenStorage` | Volatile in-memory implementation |
| `CachedTokenStorage` | Memory-caching wrapper around any `TokenStorage` |
| `AuthInterceptor` | Attaches Bearer token, handles 401 + concurrent-safe refresh |

### Interceptors

| Symbol | Description |
|---|---|
| `Interceptor` | Base class (`onRequest` / `onResponse` / `onError`) |
| `InterceptorChain` | Executes the ordered list of interceptors |
| `RetryInterceptor` | Retry on configurable status codes and exception types |
| `RetryPolicy` | Controls max attempts, delays, jitter, `Retry-After` |
| `CacheInterceptor` | HTTP response cache with four cache modes |
| `CachePolicy` | Cache mode + TTL + ETag settings |
| `CacheStore` | Abstract cache backend interface |
| `MemoryCacheStore` | Bounded LRU in-memory cache |
| `CacheEntry` | Cached response (key, body, headers, ETag, timestamp) |
| `DedupInterceptor` | In-flight request deduplication |
| `OfflineQueueInterceptor` | Captures offline writes for later replay |
| `OfflineQueueStore` | Abstract queue backend interface |
| `InMemoryOfflineQueueStore` | Volatile in-memory queue |
| `HiveOfflineQueueStore` | Persistent Hive-backed queue store |
| `QueuedRequest` | Serialisable pending request (with `toJson()` / `fromJson()`) |
| `CurlLogger` | Logs requests as `curl` commands |
| `PrettyLogger` | Structured colour request/response logger |

### GraphQL

| Symbol | Description |
|---|---|
| `GraphQLClient` | GraphQL over HTTP (query / mutation / APQ) |
| `GraphQLResponse<T>` | Result with `data`, `errors`, `extensions` |
| `GraphQLError` | Single error from the `errors` array |

### Spec

| Symbol | Description |
|---|---|
| `ApiSpec` | API contract definition |
| `EndpointSpec` | Single REST endpoint (method, path, schema, examples) |
| `Schema` | JSON Schema-like type with runtime validation |
| `RequestExample` | Request body + schema |
| `ResponseExample` | Response body + status code |
| `SpecMockAdapter` | Drives `ApiClient` from an `ApiSpec` in tests |
| `OpenApiGenerator` | Generates OpenAPI 3.1 YAML |
| `MarkdownDocGenerator` | Generates Markdown API reference |
| `BackendGuideGenerator` | Generates backend implementation guide |
| `BackendFramework` | `express` / `fastapi` / `gin` |

---

## Migration from 0.1.x

| 0.1.x | 1.0.0 |
|---|---|
| `client.get('users')` | `client.get<dynamic>('users')` |
| `ApiClientConfig(requestInterceptor: x, responseInterceptor: y)` | `ApiClientConfig(interceptors: [x, y])` |
| Untyped response wrapper | `ApiResult<T>` (`T` defaults to `dynamic`) |
| Manual 401 retry logic | Built-in via `AuthInterceptor` + `refreshToken` |
| Manual retry-on-503 | `RetryInterceptor(policy: RetryPolicy.exponential(...))` |
| `lib/core/api_client.dart` | `lib/src/core/api_client.dart` |
| `lib/core/token_storage.dart` | `lib/src/auth/token_storage.dart` |

---

## Test suite

**405 root-package tests + 4 example tests — all passing** (verified with
`flutter test` at the repo root and in `example/`):

```text
$ flutter test
$ (cd example && flutter test)
All tests passed.
```

| File | Coverage |
|---|---|
| `flutter_api_client_test.dart` | Client instantiation, `ApiResult` convenience access, token storage, request options, cancel tokens, query building |
| `api_result_test.dart` | `ApiResult` mapping/accessors, successful parse failures, empty-body success semantics, `ApiException` subtypes |
| `mock_adapter_test.dart` | Mock routing/capture, retry, dedup, cache, auth refresh queue, cancellation |
| `retry_error_test.dart` | `RetryInterceptor.onError` behavior for network, timeout, exhaustion, and non-retryable HTTP errors |
| `cache_interceptor_test.dart` | `networkFirst`, `cacheOnly`, `staleWhileRevalidate`, ETag / 304, in-memory LRU behavior |
| `offline_queue_test.dart` | Queue store operations and offline enqueue rules |
| `logger_test.dart` | cURL / pretty logging, redaction, truncation, and error logging |
| `utilities_test.dart` | `FormData`, `CancelToken`, `buildUri`, `CachedTokenStorage`, auth edge cases |
| `spec_test.dart` | `ApiSpec`, `SpecMockAdapter`, generators, and schema validation |
| `graphql_test.dart` | GraphQL client flows, validation, status overrides, and generator output |
| `gen_cli_test.dart` | CLI generator selection and generated spec discovery |
| `test_generator_test.dart` | Generated test scaffold output |
| `default_http_adapter_test.dart` | Transport: body encoding, header handling, response coalescing |
| `bugfix_core_test.dart` / `bugfix_http_test.dart` / `bugfix_interceptors_test.dart` / `bugfix_spec_test.dart` / `fixes_test.dart` | Regression tests pinning fixed bugs (auth-token leak guard, single `Content-Type` merge, streaming error-path drain, APQ hash fallback, dedup-on-retry no deadlock) |
Run with coverage:

```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

---

## License

[MIT](LICENSE) — © 2024 Dhiraj Nikam
