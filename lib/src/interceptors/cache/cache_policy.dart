import '../../core/policies.dart';

/// How a request interacts with the cache.
enum CacheMode { networkFirst, cacheFirst, staleWhileRevalidate, cacheOnly }

class CachePolicy implements CachePolicyInterface {
  const CachePolicy({
    required this.mode,
    this.ttl = const Duration(minutes: 5),
    this.useEtag = true,
  });

  final CacheMode mode;
  final Duration ttl;
  final bool useEtag;

  factory CachePolicy.networkFirst({
    Duration ttl = const Duration(minutes: 5),
  }) =>
      CachePolicy(mode: CacheMode.networkFirst, ttl: ttl);
  factory CachePolicy.cacheFirst({Duration ttl = const Duration(minutes: 5)}) =>
      CachePolicy(mode: CacheMode.cacheFirst, ttl: ttl);
  factory CachePolicy.staleWhileRevalidate(Duration ttl) =>
      CachePolicy(mode: CacheMode.staleWhileRevalidate, ttl: ttl);
  factory CachePolicy.cacheOnly() =>
      const CachePolicy(mode: CacheMode.cacheOnly);
}
