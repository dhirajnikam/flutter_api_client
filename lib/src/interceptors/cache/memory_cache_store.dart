import 'cache_store.dart';

/// Bounded in-memory LRU cache store.
///
/// Evicts the least-recently-used entry when either bound is exceeded:
/// [maxEntries] (count) and, if set, [maxBytes] (total body bytes). Entry
/// count alone is a poor proxy for memory when bodies range from a few
/// hundred bytes to several megabytes.
class MemoryCacheStore implements CacheStore {
  /// Creates a store bounded by [maxEntries] and, optionally, [maxBytes].
  MemoryCacheStore({this.maxEntries = 256, this.maxBytes});

  /// Maximum number of entries kept before the least-recently-used is evicted.
  final int maxEntries;

  /// Optional cap on the sum of cached body bytes. `null` disables the cap.
  final int? maxBytes;

  final Map<String, CacheEntry> _entries = {};
  int _totalBytes = 0;

  @override
  Future<CacheEntry?> read(String key) async {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry; // bump to MRU
    return entry;
  }

  @override
  Future<void> write(CacheEntry entry) async {
    final existing = _entries.remove(entry.key);
    if (existing != null) _totalBytes -= existing.bodyBytes.length;
    _entries[entry.key] = entry;
    _totalBytes += entry.bodyBytes.length;
    _evict();
  }

  void _evict() {
    final byteCap = maxBytes;
    while (_entries.length > maxEntries ||
        (byteCap != null && _totalBytes > byteCap && _entries.length > 1)) {
      final oldest = _entries.keys.first;
      final removed = _entries.remove(oldest);
      if (removed != null) _totalBytes -= removed.bodyBytes.length;
    }
  }

  @override
  Future<void> delete(String key) async {
    final removed = _entries.remove(key);
    if (removed != null) _totalBytes -= removed.bodyBytes.length;
  }

  @override
  Future<void> clear() async {
    _entries.clear();
    _totalBytes = 0;
  }
}
