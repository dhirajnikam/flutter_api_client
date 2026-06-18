import 'dart:typed_data';

/// A cached HTTP response entry.
class CacheEntry {
  /// Creates an entry stored under [key], captured at [savedAt].
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

  /// Cached response status code.
  final int statusCode;

  /// Cached response headers.
  final Map<String, String> headers;

  /// Cached response body bytes.
  final Uint8List bodyBytes;

  /// When this entry was written; freshness is measured from here.
  final DateTime savedAt;

  /// ETag for conditional revalidation, if the response carried one.
  final String? etag;

  /// Whether the entry is still within its [ttl] freshness window.
  bool isFresh(Duration ttl) => DateTime.now().difference(savedAt) <= ttl;
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
