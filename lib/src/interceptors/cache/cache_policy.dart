import '../../core/policies.dart';

/// How a request interacts with the cache.
enum CacheMode { networkFirst, cacheFirst, staleWhileRevalidate, cacheOnly }

/// How the [CacheInterceptor] should treat a given request.
class CachePolicy implements CachePolicyInterface {
  /// Creates a policy with an explicit [mode].
  const CachePolicy({
    required this.mode,
    this.ttl = const Duration(minutes: 5),
    this.useEtag = true,
  });

  /// The read/write strategy to apply.
  final CacheMode mode;

  /// How long a cached entry is considered fresh before it must revalidate.
  final Duration ttl;

  /// Whether to send `If-None-Match` from a stored ETag to enable 304
  /// revalidation.
  final bool useEtag;

  /// Always hit the network, falling back to the cache on failure.
  factory CachePolicy.networkFirst({
    Duration ttl = const Duration(minutes: 5),
  }) =>
      CachePolicy(mode: CacheMode.networkFirst, ttl: ttl);

  /// Serve a fresh cached entry without a network call; otherwise fetch.
  factory CachePolicy.cacheFirst({Duration ttl = const Duration(minutes: 5)}) =>
      CachePolicy(mode: CacheMode.cacheFirst, ttl: ttl);

  /// Serve a fresh cached entry immediately; when the entry is stale,
  /// revalidate against the origin (sending `If-None-Match` when an ETag is
  /// stored) before returning. Background revalidation is not yet implemented.
  ///
  /// Freshness is `now - savedAt <= ttl`, so [Duration.zero] makes every entry
  /// stale the instant it is written: the cache is never served on the request
  /// path, and the stored body is only ever returned by the `onError` fallback
  /// when the network is unreachable. That is a useful fallback-only
  /// configuration — always fetch live, but degrade to the last-known-good
  /// body offline — rather than a degenerate one.
  factory CachePolicy.staleWhileRevalidate(Duration ttl) =>
      CachePolicy(mode: CacheMode.staleWhileRevalidate, ttl: ttl);

  /// Serve only from cache; never touch the network (504 on a miss).
  factory CachePolicy.cacheOnly() =>
      const CachePolicy(mode: CacheMode.cacheOnly);
}
