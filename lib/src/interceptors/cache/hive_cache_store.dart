import 'dart:convert';
import 'dart:typed_data';

import 'package:hive/hive.dart';

import 'cache_store.dart';

/// Persistent Hive-backed cache store.
///
/// Stores each [CacheEntry] as a JSON string in a user-supplied `Hive` box,
/// so cached responses survive app restarts — combined with
/// `CachePolicy.cacheFirst` or `CachePolicy.cacheOnly` this gives real
/// offline reads. Mirrors `HiveOfflineQueueStore` on the write side.
///
/// ```dart
/// final box = await Hive.openBox<String>('http_cache');
/// CacheInterceptor(
///   store: HiveCacheStore(box, maxEntries: 512),
///   defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(minutes: 10)),
/// )
/// ```
///
/// Corrupt or partially-written records (e.g. from a crash mid-write) are
/// treated as cache misses and deleted, never thrown.
class HiveCacheStore implements CacheStore {
  /// Creates a store backed by an open Hive [box] of JSON strings.
  ///
  /// When [maxEntries] is set, writing past the cap evicts the entries with
  /// the oldest `savedAt` first. `null` leaves the box unbounded.
  HiveCacheStore(this.box, {this.maxEntries});

  /// The Hive box holding one JSON-encoded [CacheEntry] per identity key.
  final Box<String> box;

  /// Optional cap on stored entries; oldest `savedAt` evicted first.
  final int? maxEntries;

  @override
  Future<CacheEntry?> read(String key) async {
    final raw = box.get(key);
    if (raw == null) return null;
    final entry = _decode(raw);
    if (entry == null) {
      // Corrupt record: drop it so it cannot shadow a future write.
      await box.delete(key);
      return null;
    }
    return entry;
  }

  @override
  Future<void> write(CacheEntry entry) async {
    await box.put(entry.key, jsonEncode(_toJson(entry)));
    final cap = maxEntries;
    if (cap != null && box.length > cap) {
      await _evictOldest(box.length - cap);
    }
  }

  @override
  Future<void> delete(String key) => box.delete(key);

  @override
  Future<void> clear() async {
    await box.clear();
  }

  Map<String, Object?> _toJson(CacheEntry e) => {
        'key': e.key,
        'statusCode': e.statusCode,
        'headers': e.headers,
        'body': base64Encode(e.bodyBytes),
        'savedAt': e.savedAt.toIso8601String(),
        if (e.etag != null) 'etag': e.etag,
      };

  CacheEntry? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final key = decoded['key'];
      final statusCode = decoded['statusCode'];
      final body = decoded['body'];
      final savedAtRaw = decoded['savedAt'];
      if (key is! String ||
          statusCode is! int ||
          body is! String ||
          savedAtRaw is! String) {
        return null;
      }
      final savedAt = DateTime.tryParse(savedAtRaw);
      if (savedAt == null) return null;

      final headers = <String, String>{};
      final rawHeaders = decoded['headers'];
      if (rawHeaders is Map) {
        for (final entry in rawHeaders.entries) {
          final k = entry.key;
          final v = entry.value;
          if (k is String && v is String) headers[k] = v;
        }
      }

      final etag = decoded['etag'];
      return CacheEntry(
        key: key,
        statusCode: statusCode,
        headers: headers,
        bodyBytes: Uint8List.fromList(base64Decode(body)),
        savedAt: savedAt,
        etag: etag is String ? etag : null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _evictOldest(int count) async {
    // Decode savedAt for every record once; undecodable records sort first so
    // corruption is evicted before real data.
    final dated = <(dynamic, DateTime)>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      DateTime savedAt = DateTime.fromMillisecondsSinceEpoch(0);
      if (raw != null) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final parsed = decoded['savedAt'];
            if (parsed is String) {
              savedAt = DateTime.tryParse(parsed) ?? savedAt;
            }
          }
        } catch (_) {
          // keep epoch → evicted first
        }
      }
      dated.add((key, savedAt));
    }
    dated.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (key, _) in dated.take(count)) {
      await box.delete(key);
    }
  }
}
