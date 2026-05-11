import 'cache_store.dart';

/// Bounded in-memory LRU cache store.
class MemoryCacheStore implements CacheStore {
  MemoryCacheStore({this.maxEntries = 256});

  final int maxEntries;
  final Map<String, CacheEntry> _entries = {};

  @override
  Future<CacheEntry?> read(String key) async {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry; // bump to MRU
    return entry;
  }

  @override
  Future<void> write(CacheEntry entry) async {
    _entries[entry.key] = entry;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }
}
