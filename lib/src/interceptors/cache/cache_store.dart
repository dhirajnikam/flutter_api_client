import 'dart:typed_data';

/// A cached HTTP response entry.
class CacheEntry {
  CacheEntry({
    required this.key,
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.savedAt,
    this.etag,
  });

  /// Identity key this entry is stored under (see `requestIdentityKey`).
  final String key;

  final int statusCode;

  final Map<String, String> headers;

  final Uint8List bodyBytes;

  /// When this entry was written; freshness is measured from here.
  final DateTime savedAt;

  /// ETag for conditional revalidation, if the response carried one.
  final String? etag;

  /// Whether the entry is still within its [ttl] freshness window.
  ///
  /// A zero (or negative) [ttl] is never fresh, even when `DateTime.now()`
  /// returns the very instant the entry was written, so
  /// `CachePolicy.staleWhileRevalidate(Duration.zero)` stays fallback-only
  /// regardless of clock resolution. A non-zero [ttl] is an inclusive bound.
  bool isFresh(Duration ttl) =>
      ttl > Duration.zero && DateTime.now().difference(savedAt) <= ttl;
}

/// Pluggable cache backend. Implement this to persist cached responses
/// somewhere other than memory.
abstract class CacheStore {
  /// Returns the entry for [key], or `null` if absent.
  Future<CacheEntry?> read(String key);

  /// Stores [entry], replacing any existing entry with the same key.
  Future<void> write(CacheEntry entry);

  /// Removes the entry for [key], if present.
  Future<void> delete(String key);

  /// Removes all entries.
  Future<void> clear();
}

/// A [CacheStore] that can enumerate the keys it holds.
///
/// `CacheInterceptor.evictWhere` uses this capability to drop a subset of
/// entries — invalidating one list endpoint after a write — instead of
/// clearing the whole store. Both built-in stores provide it.
///
/// This is a separate interface rather than a method on [CacheStore] so that
/// existing custom stores keep compiling: Dart's `implements` requires every
/// member of an interface even when a default body is supplied, so adding
/// `keys()` to [CacheStore] would break every `implements CacheStore` in the
/// wild. Stores that do not implement this simply make selective eviction a
/// no-op. Same shape as `PeekableOfflineQueueStore` on the queue side.
abstract class EnumerableCacheStore implements CacheStore {
  /// Every key currently held.
  ///
  /// Keys are `requestIdentityKey` values — `METHOD url` followed by the
  /// sorted request headers — so callers generally cannot reconstruct one by
  /// hand; matching on the key text is the practical way to select entries.
  Future<Iterable<String>> keys();
}
