/// Flutter API Client — a production-ready, type-safe HTTP client for Flutter/Dart.
///
/// ## Key Features
///
/// ### Core HTTP Client
/// - Type-safe generic methods: `get<T>`, `post<T>`, `put<T>`, `patch<T>`,
///   `delete<T>`, and `query<T>` (the safe-with-body HTTP QUERY method)
/// - Sealed `ApiResult<T>` with exhaustive `Success`/`Failure` pattern matching
/// - Custom decoders to transform JSON directly to your model types
/// - Multiple response modes: JSON, bytes, and plain text (real streaming is
///   available separately via `ApiClient.stream()`)
/// - Multipart file uploads with progress tracking
/// - Automatic query parameter encoding
///
/// ### Authentication & Security
/// - Pluggable [TokenStorage] interface for secure token persistence
/// - Concurrent-safe 401 token refresh with request queue
/// - Automatic Bearer token injection
/// - Header redaction in logs for sensitive data protection
///
/// ### Resilience & Performance
/// - [RetryInterceptor]: Exponential backoff with jitter and `Retry-After` support
/// - [CacheInterceptor]: Four cache strategies with ETag validation
/// - [DedupInterceptor]: Collapse identical in-flight requests
/// - [OfflineQueueInterceptor]: Persist failed writes for later replay
/// - [CancelToken]: Abort multiple related requests at once
///
/// ### Spec-Driven Development
/// - [ApiSpec]: Define your API contract once
/// - [SpecMockAdapter]: Schema-validating mock for tests
/// - [OpenApiGenerator]: Generate OpenAPI 3.1 docs
/// - [MarkdownDocGenerator]: Create developer-friendly API references
/// - [BackendGuideGenerator]: Produce implementation guides for your backend team
/// - [TestGenerator]: Generate complete runnable test suites
///
/// ### GraphQL Support
/// - [GraphQLClient]: Query, mutation, and APQ support
/// - Typed error handling with [GraphQLError]
/// - Variable validation and SDL generation from specs
///
/// ### Testing
/// - [MockAdapter]: Route-based mocking with request capture
/// - No external mock dependencies
///
/// ## Quick Start
///
/// ```dart
/// final client = ApiClient(
///   ApiClientConfig(
///     baseUrl: 'https://api.example.com',
///     interceptors: [
///       RetryInterceptor(policy: RetryPolicy()),
///       CacheInterceptor(store: MemoryCacheStore()),
///       PrettyLogger(),
///     ],
///   ),
/// );
///
/// final result = await client.get<User>('users/me', decoder: (json) => User.fromJson(json as Map<String, dynamic>));
/// result.when(
///   success: (user) => print('Hello ${user.name}'),
///   failure: (error) => print('Error: ${error.message}'),
/// );
/// ```
///
/// See `CHANGELOG.md` for what changed in each release.
library;

// Core types
export 'src/core/api_exception.dart';
export 'src/core/api_result.dart';
export 'src/core/cancel_token.dart';
export 'src/core/form_data.dart';
export 'src/core/policies.dart';
export 'src/core/query.dart';
export 'src/core/request_options.dart';
export 'src/core/response_type.dart';
export 'src/core/serialization.dart';

// Client
export 'src/client/api_client.dart';
export 'src/client/api_client_config.dart';
export 'src/response/response_handler.dart';

// Auth
export 'src/auth/auth_interceptor.dart';
export 'src/auth/cached_token_storage.dart';
export 'src/auth/memory_token_storage.dart';
export 'src/auth/token_storage.dart';

// HTTP
export 'src/http/default_http_adapter.dart';
export 'src/http/http_adapter.dart';
export 'src/http/http_stream_response.dart';
export 'src/http/mock_adapter.dart';

// Interceptors
export 'src/interceptors/interceptor.dart';
export 'src/interceptors/interceptor_chain.dart';
export 'src/interceptors/cache/cache_interceptor.dart';
export 'src/interceptors/cache/cache_policy.dart';
export 'src/interceptors/cache/cache_store.dart';
export 'src/interceptors/cache/hive_cache_store.dart';
export 'src/interceptors/cache/memory_cache_store.dart';
export 'src/interceptors/circuit_breaker/circuit_breaker_interceptor.dart';
export 'src/interceptors/dedup/dedup_interceptor.dart';
export 'src/interceptors/logging/curl_logger.dart';
export 'src/interceptors/logging/pretty_logger.dart';
export 'src/interceptors/retry/retry_interceptor.dart';
export 'src/interceptors/retry/retry_policy.dart';

// Offline queue
export 'src/offline/hive_offline_queue_store.dart';
export 'src/offline/offline_auto_replay.dart';
export 'src/offline/offline_mutations.dart';
export 'src/offline/offline_queue.dart';
export 'src/offline/offline_queue_interceptor.dart';
export 'src/offline/offline_queue_replayer.dart';
export 'src/offline/offline_sync_manager.dart';

// Spec
export 'src/spec/api_spec.dart';
export 'src/spec/backend_guide_generator.dart';
export 'src/spec/examples.dart';
export 'src/spec/graphql_spec.dart';
export 'src/spec/markdown_doc_generator.dart';
export 'src/spec/openapi_generator.dart';
export 'src/spec/schema.dart';
export 'src/spec/spec_mock_adapter.dart';
export 'src/spec/test_generator.dart';

// Gen
export 'src/gen/api_spec_entry.dart';

// GraphQL
export 'src/graphql/graphql_client.dart';
export 'src/graphql/graphql_error.dart';
export 'src/graphql/graphql_response.dart';
