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

  final String key;
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
  final DateTime savedAt;
  final String? etag;

  bool isFresh(Duration ttl) => DateTime.now().difference(savedAt) <= ttl;
}

/// Pluggable cache backend.
abstract class CacheStore {
  Future<CacheEntry?> read(String key);
  Future<void> write(CacheEntry entry);
  Future<void> delete(String key);
  Future<void> clear();
}
