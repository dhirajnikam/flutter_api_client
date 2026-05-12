/// Flutter API Client — a reusable, extensible HTTP client for Flutter/Dart.
///
/// 2.0.0 highlights:
///   * Unified `ApiResult<T>` — single sealed type for all HTTP methods
///   * Real multi-request `CancelToken`
///   * `RetryPolicy` (exponential backoff + jitter + `Retry-After`)
///   * Concurrent-safe auth refresh queue
///   * Cache interceptor (memory store + pluggable disk) with cache modes
///   * Request deduplication
///   * cURL + pretty loggers (with redaction)
///   * Pluggable `HttpAdapter` and a built-in `MockAdapter`
///   * Spec-driven endpoints: one [ApiSpec] generates a mock adapter,
///     OpenAPI, an API reference, and a backend implementation guide.
library;

// Core
export 'src/core/api_client.dart';
export 'src/core/api_exception.dart';
export 'src/core/api_result.dart';
export 'src/core/cancel_token.dart';
export 'src/core/form_data.dart';
export 'src/core/query.dart';
export 'src/core/request_options.dart';
export 'src/core/response_type.dart';

// Auth
export 'src/auth/auth_interceptor.dart';
export 'src/auth/cached_token_storage.dart';
export 'src/auth/memory_token_storage.dart';
export 'src/auth/token_storage.dart';

// HTTP
export 'src/http/default_http_adapter.dart' hide encodeBody;
export 'src/http/http_adapter.dart';
export 'src/http/mock_adapter.dart';

// Interceptors
export 'src/interceptors/interceptor.dart';
export 'src/interceptors/interceptor_chain.dart';
export 'src/interceptors/cache/cache_interceptor.dart';
export 'src/interceptors/cache/cache_policy.dart';
export 'src/interceptors/cache/cache_store.dart';
export 'src/interceptors/cache/memory_cache_store.dart';
export 'src/interceptors/dedup/dedup_interceptor.dart';
export 'src/interceptors/logging/curl_logger.dart';
export 'src/interceptors/logging/pretty_logger.dart';
export 'src/interceptors/offline/offline_queue.dart';
export 'src/interceptors/offline/offline_queue_interceptor.dart';
export 'src/interceptors/retry/retry_interceptor.dart';
export 'src/interceptors/retry/retry_policy.dart';

// Response
export 'src/response/response_handler.dart';
export 'src/response/response_handler_interface.dart';

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
