/// Marker interfaces for interceptor policies, declared in `core` so
/// [RequestOptions] can reference them with a real type instead of `Object?`.
///
/// The concrete policies live in the `interceptors` layer (which depends on
/// `core`), so `core` cannot import them without creating a dependency cycle.
/// Declaring the contracts here and having the concrete classes implement them
/// inverts the dependency: `interceptors` points at `core`, never the reverse.
library;

/// Implemented by `RetryPolicy` in
/// `interceptors/retry/retry_policy.dart`. Lets a [RequestOptions] carry a
/// per-request retry policy with compile-time safety.
abstract interface class RetryPolicyInterface {}

/// Implemented by `CachePolicy` in
/// `interceptors/cache/cache_policy.dart`. See [RetryPolicyInterface].
abstract interface class CachePolicyInterface {}
