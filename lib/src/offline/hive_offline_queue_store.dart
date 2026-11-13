import 'dart:convert';

import 'package:hive/hive.dart';

import 'offline_queue.dart';

/// Persistent Hive-backed queue store.
class HiveOfflineQueueStore implements PeekableOfflineQueueStore {
  HiveOfflineQueueStore(this.box);

  /// The Hive box holding one JSON-encoded [QueuedRequest] per id.
  final Box<String> box;

  @override
  Future<void> enqueue(QueuedRequest request) async {
    await box.put(request.id, jsonEncode(request.toJson()));
  }

  /// Parses every record defensively: a single corrupt or partially-written
  /// value (e.g. from a crash mid-write) must not throw and abandon the whole
  /// queue. Bad entries are skipped; everything decodable is still replayed.
  List<QueuedRequest> _decodeAll() {
    final out = <QueuedRequest>[];
    for (final value in box.values) {
      QueuedRequest? parsed;
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          parsed = QueuedRequest.tryFromJson(decoded.cast<String, Object?>());
        }
      } catch (_) {
        parsed = null;
      }
      if (parsed != null) out.add(parsed);
    }
    return out..sort(compareQueuedRequests);
  }

  @override
  Future<List<QueuedRequest>> drain() async {
    final out = _decodeAll();
    await box.clear();
    return out;
  }

  @override
  Future<List<QueuedRequest>> peekAll() async => _decodeAll();

  @override
  Future<void> remove(String id) async {
    await box.delete(id);
  }

  @override
  Future<int> get length async => box.length;
}
