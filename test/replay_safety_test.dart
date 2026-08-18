// Per-request replay-safety opt-out (QueuedRequest.replaySafety).
//
// The peekable replay path is at-least-once: a request stays persisted until
// its send settles, so an interruption between send and remove resends it.
// That is right for idempotent endpoints and wrong for a plain create POST,
// which would produce a duplicate record. These tests pin the opt-out.

import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transport that dies partway through the send, standing in for the crash
/// window the two guarantees differ over: the request left the queue, but the
/// pass never reached the code that removes it.
class _CrashingAdapter implements HttpAdapter {
  int calls = 0;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    calls++;
    throw const NetworkError('connection dropped mid-send');
  }

  @override
  void close() {}
}

class _OkAdapter implements HttpAdapter {
  final List<AdapterRequest> seen = [];

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    seen.add(request);
    return AdapterResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      bodyBytes: Uint8List.fromList('{}'.codeUnits),
    );
  }

  @override
  void close() {}
}

QueuedRequest _req(
  String id, {
  ReplaySafety safety = ReplaySafety.atLeastOnce,
  int attempts = 0,
}) =>
    QueuedRequest(
      id: id,
      method: 'POST',
      endpoint: '/items',
      headers: const {},
      body: const {'name': 'x'},
      createdAt: DateTime(2024),
      attempts: attempts,
      replaySafety: safety,
    );

void main() {
  group('QueuedRequest.replaySafety', () {
    test('defaults to atLeastOnce, preserving existing behaviour', () {
      expect(_req('a').replaySafety, ReplaySafety.atLeastOnce);
    });

    test('survives a JSON round trip', () {
      final json = _req('a', safety: ReplaySafety.atMostOnce).toJson();
      expect(QueuedRequest.fromJson(json).replaySafety,
          ReplaySafety.atMostOnce);
    });

    test('records predating the field parse as atLeastOnce', () {
      // Exactly what a 1.6.0 store wrote: no replaySafety key at all.
      final legacy = <String, Object?>{
        'id': 'old',
        'method': 'POST',
        'endpoint': '/items',
        'headers': <String, String>{},
        'createdAt': DateTime(2024).toIso8601String(),
        'attempts': 0,
        'priority': 0,
      };
      expect(QueuedRequest.fromJson(legacy).replaySafety,
          ReplaySafety.atLeastOnce);
    });

    test('withAttempt carries the safety mode through a retry', () {
      final next = _req('a', safety: ReplaySafety.atMostOnce).withAttempt();
      expect(next.replaySafety, ReplaySafety.atMostOnce);
      expect(next.attempts, 1);
    });
  });

  group('OfflineQueueReplayer honours replaySafety', () {
    test('atMostOnce request is gone from the store before its send lands',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(_req('create', safety: ReplaySafety.atMostOnce));

      // A transport that inspects the queue at the moment of the send: this is
      // the crash window. For atMostOnce the record must ALREADY be gone.
      late int lengthDuringSend;
      final adapter = _InspectingAdapter(() async {
        lengthDuringSend = await store.length;
      });
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );
      await OfflineQueueReplayer(store: store, client: client).replay();

      expect(lengthDuringSend, 0,
          reason: 'atMostOnce must detach before sending, so an interruption '
              'here drops the request instead of duplicating it');
    });

    test('atLeastOnce request is still persisted during its send', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(_req('update'));

      late int lengthDuringSend;
      final adapter = _InspectingAdapter(() async {
        lengthDuringSend = await store.length;
      });
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );
      await OfflineQueueReplayer(store: store, client: client).replay();

      expect(lengthDuringSend, 1,
          reason: 'the default guarantee is unchanged: stay persisted until '
              'the send settles');
    });

    test('a crash mid-send leaves NO atMostOnce record to duplicate',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(_req('create', safety: ReplaySafety.atMostOnce));
      final adapter = _CrashingAdapter();
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );
      final replayer = OfflineQueueReplayer(store: store, client: client);

      // First pass: the send fails transiently. atLeastOnce would re-enqueue;
      // atMostOnce accepts the loss rather than risking a second create, and
      // dead-letters so the caller learns the write was abandoned.
      final first = await replayer.replay();
      expect(first.deadLettered, 1);
      expect(first.reEnqueued, 0);
      expect(await store.length, 0);

      // A later pass has nothing to resend — no duplicate record.
      final second = await replayer.replay();
      expect(second.total, 0);
      expect(adapter.calls, 1);
    });

    test('an abandoned atMostOnce write reaches onDeadLetter, not silence',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(_req('create', safety: ReplaySafety.atMostOnce));
      final client = ApiClient(
        ApiClientConfig.test(
            baseUrl: 'https://x.test', adapter: _CrashingAdapter()),
      );
      final abandoned = <String>[];

      await OfflineQueueReplayer(
        store: store,
        client: client,
        onDeadLetter: (req, err) => abandoned.add(req.id),
      ).replay();

      expect(abandoned, ['create'],
          reason: 'dropping the write is the point of atMostOnce, but the '
              'caller must still be told it happened');
    });

    test('atLeastOnce still re-enqueues on a transient failure', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(_req('update'));
      final client = ApiClient(
        ApiClientConfig.test(
            baseUrl: 'https://x.test', adapter: _CrashingAdapter()),
      );

      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();

      expect(report.reEnqueued, 1);
      expect(await store.length, 1);
    });

    test('a successful atMostOnce replay still sends exactly once', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(_req('create', safety: ReplaySafety.atMostOnce));
      final adapter = _OkAdapter();
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );

      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();

      expect(report.succeeded, 1);
      expect(adapter.seen, hasLength(1));
      expect(await store.length, 0);
    });

    test('mixed queue: each request gets its own guarantee in one pass',
        () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(_req('create', safety: ReplaySafety.atMostOnce));
      await store.enqueue(_req('update'));
      final client = ApiClient(
        ApiClientConfig.test(
            baseUrl: 'https://x.test', adapter: _CrashingAdapter()),
      );

      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();

      // The create is dead-lettered and dropped; the update survives for a
      // later pass.
      expect(report.deadLettered, 1);
      expect(report.reEnqueued, 1);
      final left = await store.peekAll();
      expect(left.map((r) => r.id), ['update']);
    });
  });

  group('OfflineQueueInterceptor.replaySafetyOf', () {
    test('defaults every queued request to atLeastOnce', () async {
      final store = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: _CrashingAdapter(),
          interceptors: [OfflineQueueInterceptor(store: store)],
        ),
      );

      await client.post<dynamic>('/items', const {'name': 'x'});

      final queued = await store.peekAll();
      expect(queued.single.replaySafety, ReplaySafety.atLeastOnce);
    });

    test('marks only the endpoints the callback selects', () async {
      final store = InMemoryOfflineQueueStore();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: _CrashingAdapter(),
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              // A plain create POST must not be duplicated; the keyed PUT may.
              replaySafetyOf: (req) => req.method.toUpperCase() == 'POST'
                  ? ReplaySafety.atMostOnce
                  : ReplaySafety.atLeastOnce,
            ),
          ],
        ),
      );

      await client.post<dynamic>('/items', const {'name': 'x'});
      await client.put<dynamic>('/items/1', const {'name': 'y'});

      final queued = await store.peekAll();
      final byEndpoint = {
        for (final r in queued) r.endpoint: r.replaySafety,
      };
      expect(byEndpoint['/items'], ReplaySafety.atMostOnce);
      expect(byEndpoint['/items/1'], ReplaySafety.atLeastOnce);
    });
  });
}

/// Runs [probe] at the exact moment the request hits the transport, then fails
/// transiently. Lets a test observe queue state inside the crash window.
class _InspectingAdapter implements HttpAdapter {
  _InspectingAdapter(this.probe);

  final Future<void> Function() probe;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    await probe();
    throw const NetworkError('dropped');
  }

  @override
  void close() {}
}
