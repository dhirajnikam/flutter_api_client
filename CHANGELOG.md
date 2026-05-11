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
* For new code prefer `client.request<User>('GET', 'users/me', decoder: User.fromJson)`
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
