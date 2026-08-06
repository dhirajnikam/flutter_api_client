import 'dart:convert';

import 'package:hive/hive.dart';

/// Persists pending mutations while offline. Pluggable so users wire their
/// own storage backend.
abstract class OfflineQueueStore {
  /// Appends [request] to the queue.
  Future<void> enqueue(QueuedRequest request);

  /// Removes and returns all pending requests in replay order
  /// (see [compareQueuedRequests]: priority first, then oldest first).
  Future<List<QueuedRequest>> drain();

  /// Removes the request with the given [id], if present.
  Future<void> remove(String id);

  /// Number of pending requests.
  Future<int> get length;
}

/// An [OfflineQueueStore] that can also be read non-destructively.
///
/// `OfflineQueueReplayer` prefers this capability when the store provides it:
/// requests stay persisted until each one is individually removed after being
/// resent, so a crash mid-replay can no longer lose the not-yet-sent tail the
/// way a destructive [OfflineQueueStore.drain] can. Existing custom stores
/// that only implement [OfflineQueueStore] keep working unchanged via the
/// legacy drain-based replay path.
abstract class PeekableOfflineQueueStore implements OfflineQueueStore {
  /// Returns all pending requests in replay order WITHOUT removing them.
  Future<List<QueuedRequest>> peekAll();
}

/// Default replay ordering: higher [QueuedRequest.priority] first, then oldest
/// [QueuedRequest.createdAt] first, with [QueuedRequest.id] as a stable final
/// tiebreak. Stores sort by this on [OfflineQueueStore.drain]; the replayer can
/// override it with a custom comparator.
int compareQueuedRequests(QueuedRequest a, QueuedRequest b) {
  final byPriority = b.priority.compareTo(a.priority); // higher first
  if (byPriority != 0) return byPriority;
  final byCreatedAt = a.createdAt.compareTo(b.createdAt); // oldest first
  if (byCreatedAt != 0) return byCreatedAt;
  return a.id.compareTo(b.id);
}

/// A request captured while offline, pending replay.
class QueuedRequest {
  /// Creates a queued request record.
  QueuedRequest({
    required this.id,
    required this.method,
    required this.endpoint,
    required this.headers,
    this.body,
    required this.createdAt,
    this.attempts = 0,
    this.queryParameters,
    this.baseUrlOverride,
    this.priority = 0,
  });

  /// Unique id within the queue; also the storage key for keyed stores.
  final String id;

  /// HTTP method to replay with.
  final String method;

  /// Target endpoint to replay against.
  final String endpoint;

  /// Headers to send (the `Authorization` header is intentionally not stored).
  final Map<String, String> headers;

  /// Request body, if any.
  final Object? body;

  /// When the request was first queued; replays happen in this order.
  final DateTime createdAt;

  /// Number of replay attempts already made. Used to dead-letter poison
  /// requests that keep failing instead of replaying them forever.
  final int attempts;

  /// URL query parameters the original request carried, replayed alongside
  /// [endpoint]. `null` when the request had none (or was queued by a version
  /// that predates this field — older persisted records parse fine).
  final Map<String, dynamic>? queryParameters;

  /// Base-URL override the original request carried, if any, so the replay
  /// targets the same host the original request did.
  final String? baseUrlOverride;

  /// Replay priority; higher values replay first (default `0`). Ties break on
  /// [createdAt] then [id]. Override ordering wholesale with a comparator on the
  /// replayer if priority alone is not enough.
  final int priority;

  /// Returns a copy with [attempts] incremented by one.
  QueuedRequest withAttempt() => QueuedRequest(
        id: id,
        method: method,
        endpoint: endpoint,
        headers: headers,
        body: body,
        createdAt: createdAt,
        attempts: attempts + 1,
        queryParameters: queryParameters,
        baseUrlOverride: baseUrlOverride,
        priority: priority,
      );

  /// JSON representation for persistent stores.
  Map<String, Object?> toJson() => {
        'id': id,
        'method': method,
        'endpoint': endpoint,
        'headers': headers,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
        'attempts': attempts,
        if (queryParameters != null) 'queryParameters': queryParameters,
        if (baseUrlOverride != null) 'baseUrlOverride': baseUrlOverride,
        'priority': priority,
      };

  /// Strict parse; throws [FormatException] on a malformed record.
  factory QueuedRequest.fromJson(Map<String, Object?> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw FormatException('Malformed QueuedRequest JSON', json);
    }
    return parsed;
  }

  /// Lenient parse that returns `null` instead of throwing when a record is
  /// malformed. Persistent stores use this so one corrupt entry cannot poison
  /// an entire [OfflineQueueStore.drain] (which would silently drop every
  /// other pending mutation).
  static QueuedRequest? tryFromJson(Map<String, Object?> json) {
    final id = json['id'];
    final method = json['method'];
    final endpoint = json['endpoint'];
    final createdAtRaw = json['createdAt'];
    if (id is! String ||
        method is! String ||
        endpoint is! String ||
        createdAtRaw is! String) {
      return null;
    }
    final createdAt = DateTime.tryParse(createdAtRaw);
    if (createdAt == null) return null;

    final headers = <String, String>{};
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String) {
          headers[key] = value;
        }
      }
    }

    final attemptsRaw = json['attempts'];
    final attempts = attemptsRaw is int
        ? attemptsRaw
        : (attemptsRaw is num ? attemptsRaw.toInt() : 0);

    Map<String, dynamic>? queryParameters;
    final rawQuery = json['queryParameters'];
    if (rawQuery is Map) {
      queryParameters = <String, dynamic>{};
      for (final entry in rawQuery.entries) {
        final key = entry.key;
        if (key is String) queryParameters[key] = entry.value;
      }
    }

    final rawBaseUrl = json['baseUrlOverride'];

    final priorityRaw = json['priority'];
    final priority = priorityRaw is int
        ? priorityRaw
        : (priorityRaw is num ? priorityRaw.toInt() : 0);

    return QueuedRequest(
      id: id,
      method: method,
      endpoint: endpoint,
      headers: headers,
      body: json['body'],
      createdAt: createdAt,
      attempts: attempts < 0 ? 0 : attempts,
      queryParameters: queryParameters,
      baseUrlOverride: rawBaseUrl is String ? rawBaseUrl : null,
      priority: priority,
    );
  }
}

/// Default in-memory queue store (volatile). Replace with a persistent
/// implementation for real offline support.
class InMemoryOfflineQueueStore implements PeekableOfflineQueueStore {
  final List<QueuedRequest> _items = [];

  @override
  Future<void> enqueue(QueuedRequest request) async {
    _items.add(request);
  }

  @override
  Future<List<QueuedRequest>> drain() async {
    // Honour the OfflineQueueStore.drain contract (priority first, then oldest
    // createdAt), matching HiveOfflineQueueStore. Insertion order usually agrees
    // on createdAt, but priority and re-enqueues require an explicit sort.
    final out = List<QueuedRequest>.from(_items)..sort(compareQueuedRequests);
    _items.clear();
    return out;
  }

  @override
  Future<List<QueuedRequest>> peekAll() async =>
      List<QueuedRequest>.from(_items)..sort(compareQueuedRequests);

  @override
  Future<void> remove(String id) async {
    _items.removeWhere((r) => r.id == id);
  }

  @override
  Future<int> get length async => _items.length;
}

/// Persistent Hive-backed queue store.
class HiveOfflineQueueStore implements PeekableOfflineQueueStore {
  /// Creates a store backed by an open Hive [box] of JSON strings.
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
