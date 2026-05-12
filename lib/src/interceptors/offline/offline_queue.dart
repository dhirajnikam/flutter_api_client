/// Persists pending mutations while offline. Pluggable so users wire their
/// own storage backend.
abstract class OfflineQueueStore {
  Future<void> enqueue(QueuedRequest request);
  Future<List<QueuedRequest>> drain();
  Future<void> remove(String id);
  Future<int> get length;
}

class QueuedRequest {
  QueuedRequest({
    required this.id,
    required this.method,
    required this.endpoint,
    required this.headers,
    this.body,
    required this.createdAt,
  });

  final String id;
  final String method;
  final String endpoint;
  final Map<String, String> headers;
  final Object? body;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'method': method,
        'endpoint': endpoint,
        'headers': headers,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// Default in-memory queue store (volatile). Replace with a persistent
/// implementation for real offline support.
class InMemoryOfflineQueueStore implements OfflineQueueStore {
  final List<QueuedRequest> _items = [];

  @override
  Future<void> enqueue(QueuedRequest request) async {
    _items.add(request);
  }

  @override
  Future<List<QueuedRequest>> drain() async {
    final out = List<QueuedRequest>.from(_items);
    _items.clear();
    return out;
  }

  @override
  Future<void> remove(String id) async {
    _items.removeWhere((r) => r.id == id);
  }

  @override
  Future<int> get length async => _items.length;
}
