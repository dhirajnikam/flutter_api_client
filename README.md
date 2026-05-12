# flutter_api_client

A type-safe, extensible HTTP client for Flutter/Dart. Ships with retries,
caching, request deduplication, concurrent-safe token refresh, an offline
write queue, structured logging, and a **spec-driven endpoint system** that
turns one `ApiSpec` into a working mock adapter, an OpenAPI 3.1 document,
a Markdown API reference, and a backend implementation guide.

[![pub package](https://img.shields.io/pub/v/flutter_api_client.svg)](https://pub.dev/packages/flutter_api_client)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-107%20passing-brightgreen)](#test-suite)

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
  flutter_api_client: ^2.0.0

dev_dependencies:
  build_runner: ^2.4.0
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

dart test --concurrency=8
```

---

## Why this package

| Feature | `dio` | `flutter_api_client` 1.0 |
|---|---|---|
| Typed `get<T>` / `post<T>` with decoder | manual | built-in |
| Sealed `ApiResult<T>` (Success / Failure) | no | built-in |
| Multi-request `CancelToken` | yes | yes |
| Exponential backoff + jitter + `Retry-After` | `dio_smart_retry` | built-in |
| Concurrent-safe 401 refresh queue | DIY | built-in |
| Cache: `networkFirst`, `cacheFirst`, `staleWhileRevalidate`, `cacheOnly` | `dio_cache_interceptor` | built-in |
| ETag / `If-None-Match` revalidation | plugin | built-in |
| Request dedup / in-flight coalescing | DIY | built-in |
| Offline write queue (pluggable storage) | DIY | built-in |
| cURL + pretty logger with redaction | `pretty_dio_logger` | built-in |
| Pluggable transport (`HttpAdapter`) | yes | yes |
| Built-in `MockAdapter` for tests | `http_mock_adapter` | built-in |
| Spec → mock + OpenAPI + docs + backend guide | no | **yes** |
| Upload / download progress callbacks | yes | yes |
| Per-request response mode (JSON / bytes / text / stream) | yes | yes |
| GraphQL query / mutation / APQ | no | built-in |

---

## Installation

```yaml
# pubspec.yaml
dependencies:
  flutter_api_client: ^1.0.0
```

```bash
flutter pub get
```

**Runtime dependencies:** [`http`](https://pub.dev/packages/http) ^1.2.2,
[`meta`](https://pub.dev/packages/meta) ^1.12.0,
[`collection`](https://pub.dev/packages/collection) ^1.18.0.

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
final result = await client.request<User>(
  'GET',
  'users/me',
  decoder: User.fromJson,
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
| `responseHandler` | `ResponseHandlerInterface?` | built-in | Custom error-message extractor |
| `interceptors` | `List<Interceptor>` | `[]` | Applied in declaration order |
| `adapter` | `HttpAdapter?` | `DefaultHttpAdapter()` | Swap transport for tests or custom HTTP stacks |

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
    cachePolicy:     CachePolicy.networkFirst(),
    retryPolicy:     RetryPolicy(maxAttempts: 1),
    onReceiveProgress: (received, total) => print('$received/$total'),
  ),
);
```

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

### `CustomApiResponse<T>` — returned by all verb methods

```dart
res.isSuccess    // true for any 2xx status
res.statusCode   // HTTP status code (0 on transport error)
res.data         // T? — decoded body, or null
res.errorMessage // String? — populated when isSuccess is false
res.headers      // Map<String, String>
res.rawBody      // List<int>? — raw response bytes
```

### `ApiResult<T>` — returned by `client.request()`

A sealed type; exhaustively match with `when`:

```dart
final result = await client.request<User>(
  'GET', 'users/me', decoder: User.fromJson,
);

result.when(
  success: (user) => ...,
  failure: (err)  => ...,
);

// Convenience helpers
result.isSuccess   // bool
result.isFailure   // bool
result.dataOrNull  // T?
result.errorOrNull // ApiException?

// Transform the success value without unwrapping
final nameResult = result.map((user) => user.name); // ApiResult<String>
```

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
| `HttpError` | Non-2xx response (carries `statusCode`, `body`, `headers`) |
| `ParseError` | Response body could not be decoded |
| `UnknownError` | Any other unexpected exception |

**`CustomApiResponse` path:** exceptions are swallowed into
`isSuccess: false` + `errorMessage` — safe and simple, but less structured.

**`ApiResult` path:** exceptions surface as typed `Failure` — exhaustive
matching is possible:

```dart
final result = await client.request<dynamic>('GET', 'users/1');
if (result case Failure(:final error)) {
  switch (error) {
    case NetworkError(:final message):
      showOfflineBanner(message);
    case HttpError(:final statusCode) when statusCode == 401:
      navigateToLogin();
    case TimeoutError():
      showRetryDialog();
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

Each interceptor overrides one or more of:

```dart
Future<InterceptorResult> onRequest(InterceptedRequest req)  → ProceedResult / ResolveResult / RejectResult
Future<InterceptorResult> onResponse(InterceptedRequest, AdapterResponse) → same
Future<InterceptorResult> onError(InterceptedRequest, ApiException)       → same
```

---

### `RetryInterceptor`

Retries on configurable status codes and exception types with exponential
backoff, optional jitter, and `Retry-After` header support.

```dart
RetryInterceptor(
  policy: RetryPolicy(
    maxAttempts:     3,                         // total attempts (initial + retries)
    baseDelay:       Duration(milliseconds: 200),
    maxDelay:        Duration(seconds: 30),
    retryOnStatus:   {408, 429, 500, 502, 503, 504},
    useJitter:       true,   // randomises delay ±30%
    respectRetryAfter: true, // honours Retry-After response header
  ),
)

// Convenience factory
RetryInterceptor(policy: RetryPolicy.exponential(maxAttempts: 4))
```

**Triggers a retry:**
- Status codes in `retryOnStatus` (default: 408, 429, 500–504)
- `NetworkError` or `TimeoutError` (configurable via `retryOnException`)

**Does not trigger a retry:**
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
| `staleWhileRevalidate` | If a cached entry exists and TTL is still valid, return it immediately. On TTL expiry, return the stale entry and revalidate in the background. |
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
OfflineQueueInterceptor(
  store:    InMemoryOfflineQueueStore(), // replace with persistent store
  isOnline: () async => (await Connectivity().checkConnectivity())
                        != ConnectivityResult.none,
  methods:  {'POST', 'PUT', 'PATCH', 'DELETE'}, // default
)
```

**Replaying the queue** when connectivity returns:

```dart
final store = InMemoryOfflineQueueStore();
// ...when online:
final pending = await store.drain();
for (final req in pending) {
  try {
    await client.request<dynamic>(req.method, req.endpoint);
    // already removed from store by drain()
  } catch (_) {
    await store.enqueue(req); // re-enqueue on failure
  }
}
```

**Never enqueued:**
- GET / HEAD (idempotent reads)
- `HttpError` (4xx/5xx — server-side, not a connectivity issue)
- Requests when `isOnline()` returns `true`

For production, implement `OfflineQueueStore` on top of SQLite or Hive so
the queue survives app restarts.

---

### `CurlLogger`

Logs every request as a ready-to-paste `curl` command. Sensitive headers
are redacted by default.

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
  --data '{"email":"a@b.com","password":"secret123"}' \
  'https://api.example.com/api/v1/auth/login'
```

---

### `PrettyLogger`

Structured, colour-coded request/response logger. Response bodies are
capped at 2 000 characters (truncated with `…`).

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
│ body: {"email":"a@b.com","password":"secret123"}
└───────────────
┌─── 200 POST auth/login ───
│ content-type: application/json
│ body: {"token":"jwt","user":{"id":1}}
└───────────────
```

---

## Cancel tokens

A single `CancelToken` can be bound to multiple requests. `cancel()` aborts
every associated request without disturbing unrelated ones.

```dart
final token = CancelToken();

// Bind to multiple requests
final [feed, comments] = await Future.wait([
  client.get('feed',     options: RequestOptions(cancelToken: token)),
  client.get('comments', options: RequestOptions(cancelToken: token)),
]);

// Abort both when the user navigates away
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
import 'package:crypto/crypto.dart';
import 'dart:convert';

final gql = GraphQLClient(
  client,
  usePersistedQueries: true,
  hashQuery: (doc) => sha256.convert(utf8.encode(doc)).toString(),
);
```

On first send the client transmits only the hash. On `PersistedQueryNotFound`
it automatically falls back to the full document. Replace the default hash
(simple FNV-style) with SHA-256 for production.

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
| `CustomApiResponse<T>` | Response from verb methods |
| `ApiResult<T>` | Sealed typed result from `client.request()` |
| `Success<T>` | Successful `ApiResult` (carries `data`, `statusCode`, `headers`) |
| `Failure<T>` | Failed `ApiResult` (carries `error`, optional `statusCode`) |
| `ApiException` | Sealed base class for all errors |
| `NetworkError` | I/O / connectivity failure |
| `TimeoutError` | Request timed out |
| `CancelError` | Cancelled via `CancelToken` |
| `HttpError` | Non-2xx HTTP status (carries `statusCode`, `body`, `headers`) |
| `ParseError` | Response body decode failure |
| `UnknownError` | Catch-all |
| `CancelToken` | Abort one or more in-flight requests |
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
| `QueuedRequest` | Serialisable pending request (with `toJson()`) |
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
| Untyped `CustomApiResponse` | `CustomApiResponse<T>` (`T` defaults to `dynamic`) |
| Manual 401 retry logic | Built-in via `AuthInterceptor` + `refreshToken` |
| Manual retry-on-503 | `RetryInterceptor(policy: RetryPolicy.exponential(...))` |
| `lib/core/api_client.dart` | `lib/src/core/api_client.dart` |
| `lib/core/token_storage.dart` | `lib/src/auth/token_storage.dart` |

---

## Test suite

**107 tests — all passing** (verified against actual source code):

```
$ flutter test
All 107 tests passed.
```

| File | Tests | Coverage |
|---|---|---|
| `flutter_api_client_test.dart` | 16 | Client instantiation, `CustomApiResponse`, `MemoryTokenStorage`, `CachedTokenStorage`, `RequestOptions`, `CancelToken`, `buildQueryString` |
| `api_result_test.dart` | 17 | `ApiResult.when/map/dataOrNull/errorOrNull/isSuccess`, `ApiClient.request()` typed path, all six `ApiException` subtypes |
| `mock_adapter_test.dart` | 9 | `MockAdapter` routing + capture, `RetryInterceptor` (503), `DedupInterceptor`, `CacheInterceptor` (cacheFirst), `AuthInterceptor` 401 refresh queue, `CancelToken` abort |
| `retry_error_test.dart` | 4 | `RetryInterceptor.onError`: `NetworkError` retry, `TimeoutError` retry, exhaustion after max attempts, no retry on `HttpError` |
| `cache_interceptor_test.dart` | 9 | `networkFirst`, `cacheOnly` (miss + populated), `staleWhileRevalidate`, ETag / 304, `MemoryCacheStore` LRU eviction / clear / delete |
| `offline_queue_test.dart` | 9 | `InMemoryOfflineQueueStore` enqueue / drain / remove / `toJson`, `OfflineQueueInterceptor` enqueue on `NetworkError` / `TimeoutError`, skip on GET / `isOnline=true` / `HttpError` |
| `logger_test.dart` | 7 | `CurlLogger` format, redaction, body inclusion; `PrettyLogger` request+response, redaction, error, 2 000-char truncation |
| `utilities_test.dart` | 19 | `FormData.fromMap` (all value types), `CancelToken` listener removal, `buildUri` edge cases, `CachedTokenStorage.clearCache`, `AuthInterceptor` edge cases (empty token, custom scheme, bare token) |
| `spec_test.dart` | 10 | `ApiSpec` recording + path patterns, `SpecMockAdapter` end-to-end + 422 + status overrides, OpenAPI / Markdown / BackendGuide generators, `Schema.validate` |
| `graphql_test.dart` | 7 | `GraphQLClient` query, mutation, variable validation, unknown operation, status override, Markdown + BackendGuide GraphQL sections |

Run with coverage:

```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

---

## License

[MIT](LICENSE) — © 2024 Dhiraj Nikam
