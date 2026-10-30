// A request rejected before it left the device (circuit breaker fail-fast) is
// not the ambiguous "may have reached the server" case, so an atMostOnce write
// must be kept, not dead-lettered, and must not burn a replay attempt.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// Always fails at the transport; counts how many sends were attempted.
class _DownAdapter implements HttpAdapter {
  _DownAdapter(this.error);
  final NetworkError error;
  int sends = 0;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    sends++;
    throw error;
  }

  @override
  void close() {}
}

/// Fails while [down], otherwise answers 200; counts every send.
class _FlipAdapter implements HttpAdapter {
  bool down = true;
  int sends = 0;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    sends++;
    if (down) throw const NetworkError('down');
    return AdapterResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      bodyBytes: Uint8List.fromList(utf8.encode('{}')),
    );
  }

  @override
  void close() {}
}

QueuedRequest _post() => QueuedRequest(
      id: 'q1',
      method: 'POST',
      endpoint: 'todos',
      headers: const {},
      body: const {'title': 'x'},
      createdAt: DateTime(2024),
      replaySafety: ReplaySafety.atMostOnce,
    );

void main() {
  test('circuit breaker fail-fast error is marked as never sent', () async {
    final adapter = _DownAdapter(const NetworkError('down'));
    final client = ApiClient(ApiClientConfig(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
      interceptors: [CircuitBreakerInterceptor(failureThreshold: 1)],
    ));
    final tripped = await client.get<dynamic>('x');
    expect((tripped.error as NetworkError).sent, isTrue);

    final fast = await client.get<dynamic>('x');
    expect(adapter.sends, 1, reason: 'second call must fail fast');
    expect((fast.error as NetworkError).sent, isFalse);
  });

  test('atMostOnce write rejected by an open circuit is kept, not dropped',
      () async {
    final adapter = _DownAdapter(const NetworkError('down'));
    final client = ApiClient(ApiClientConfig(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
      interceptors: [
        CircuitBreakerInterceptor(
          failureThreshold: 1,
          cooldown: const Duration(hours: 1),
        ),
      ],
    ));
    await client.get<dynamic>('trip'); // opens the circuit

    final queue = InMemoryOfflineQueueStore();
    await queue.enqueue(_post());
    final dropped = <QueuedRequest>[];
    final outcomes = <ReplayOutcome>[];
    final replayer = OfflineQueueReplayer(
      store: queue,
      client: client,
      onDeadLetter: (r, _) => dropped.add(r),
      onOutcome: (_, o) => outcomes.add(o),
    );

    // More passes than maxAttempts: a never-sent rejection must not burn them.
    for (var i = 0; i < 5; i++) {
      final report = await replayer.replay();
      expect(report.reEnqueued, 1);
      expect(report.deadLettered, 0);
    }

    expect(adapter.sends, 1, reason: 'nothing may reach the transport');
    expect(dropped, isEmpty);
    expect(outcomes, everyElement(ReplayOutcome.reEnqueued));
    final left = await queue.peekAll();
    expect(left.single.id, 'q1');
    expect(left.single.attempts, 0);
  });

  test('atMostOnce rollback does not run for a never-sent rejection', () async {
    final adapter = _DownAdapter(const NetworkError('down'));
    final client = ApiClient(ApiClientConfig(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
      interceptors: [
        CircuitBreakerInterceptor(
          failureThreshold: 1,
          cooldown: const Duration(hours: 1),
        ),
      ],
    ));
    await client.get<dynamic>('trip');

    final queue = InMemoryOfflineQueueStore();
    final mutations = OfflineMutations(client: client, store: queue);
    final local = <String>[];
    await mutations.mutate<dynamic>(
      'POST',
      'todos',
      const {'title': 'x'},
      replaySafety: ReplaySafety.atMostOnce,
      apply: () async => local.add('x'),
      rollback: () async => local.remove('x'),
    );
    // mutate() may itself have attempted a send; start from a known state.
    expect(await queue.length, 1);

    await mutations.buildReplayer().replay();

    expect(local, ['x'], reason: 'nothing was lost, so no rollback');
    expect(await queue.length, 1);
  });

  test('atMostOnce write with an ambiguous NetworkError is still dropped',
      () async {
    final adapter = _DownAdapter(const NetworkError('connection reset'));
    final client = ApiClient(ApiClientConfig(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
    ));
    final queue = InMemoryOfflineQueueStore();
    await queue.enqueue(_post());
    final dropped = <QueuedRequest>[];

    final report = await OfflineQueueReplayer(
      store: queue,
      client: client,
      onDeadLetter: (r, _) => dropped.add(r),
    ).replay();

    expect(report.deadLettered, 1);
    expect(dropped, hasLength(1));
    expect(await queue.length, 0);
  });

  test('atLeastOnce never-sent rejection does not consume an attempt',
      () async {
    final adapter = _DownAdapter(const NetworkError('down'));
    final client = ApiClient(ApiClientConfig(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
      interceptors: [
        CircuitBreakerInterceptor(
          failureThreshold: 1,
          cooldown: const Duration(hours: 1),
        ),
      ],
    ));
    await client.get<dynamic>('trip');
    final queue = InMemoryOfflineQueueStore();
    await queue.enqueue(QueuedRequest(
      id: 'q2',
      method: 'PUT',
      endpoint: 'todos/1',
      headers: const {},
      createdAt: DateTime(2024),
    ));
    final replayer = OfflineQueueReplayer(store: queue, client: client);
    for (var i = 0; i < 5; i++) {
      await replayer.replay();
    }
    final left = await queue.peekAll();
    expect(left.single.attempts, 0);
  });

  test('kept atMostOnce write is delivered once after the cooldown elapses',
      () async {
    final adapter = _FlipAdapter();
    final client = ApiClient(ApiClientConfig(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
      interceptors: [
        CircuitBreakerInterceptor(
          failureThreshold: 1,
          cooldown: const Duration(milliseconds: 200),
        ),
      ],
    ));
    await client.get<dynamic>('trip'); // real failure opens the circuit
    expect(adapter.sends, 1);

    final queue = InMemoryOfflineQueueStore();
    await queue.enqueue(_post());
    final outcomes = <ReplayOutcome>[];
    final replayer = OfflineQueueReplayer(
      store: queue,
      client: client,
      onOutcome: (_, o) => outcomes.add(o),
    );

    final first = await replayer.replay();
    expect(first.reEnqueued, 1);
    expect(adapter.sends, 1);

    adapter.down = false;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final second = await replayer.replay();

    expect(second.succeeded, 1);
    expect(second.deadLettered, 0);
    expect(outcomes, [ReplayOutcome.reEnqueued, ReplayOutcome.succeeded]);
    expect(adapter.sends, 2, reason: 'delivered exactly once');
    expect(await queue.length, 0);
  });

  test('Hive-backed queue re-enqueues a never-sent record unchanged', () async {
    final dir = await Directory.systemTemp.createTemp('replay_never_sent');
    Hive.init(dir.path);
    final box = await Hive.openBox<String>('never_sent_queue');
    try {
      final adapter = _DownAdapter(const NetworkError('down'));
      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: adapter,
        interceptors: [
          CircuitBreakerInterceptor(
            failureThreshold: 1,
            cooldown: const Duration(hours: 1),
          ),
        ],
      ));
      await client.get<dynamic>('trip');

      final store = HiveOfflineQueueStore(box);
      await store.enqueue(_post());
      final replayer = OfflineQueueReplayer(store: store, client: client);
      for (var i = 0; i < 4; i++) {
        final report = await replayer.replay();
        expect(report.reEnqueued, 1);
        expect(report.deadLettered, 0);
      }

      final left = await store.peekAll();
      expect(left, hasLength(1));
      expect(left.single.id, 'q1');
      expect(left.single.attempts, 0);
      expect(left.single.replaySafety, ReplaySafety.atMostOnce);
      expect(adapter.sends, 1);
    } finally {
      await box.close();
      await dir.delete(recursive: true);
    }
  });

  test('NetworkError defaults to sent == true and stays const', () {
    const plain = NetworkError('x');
    const unsent = NetworkError('x', sent: false);
    expect(plain.sent, isTrue);
    expect(unsent.sent, isFalse);
    expect(identical(plain, const NetworkError('x')), isTrue);
    final withCause = NetworkError('x', cause: StateError('c'));
    expect(withCause.sent, isTrue);
    expect(withCause.cause, isA<StateError>());
  });

  // sent describes the last attempt, not the whole call: an earlier attempt may
  // have reached the transport before the breaker started rejecting.
  for (final retryFirst in [true, false]) {
    test('retry then breaker reject stays ambiguous (retryFirst=$retryFirst)',
        () async {
      final adapter = _DownAdapter(const NetworkError('reset'));
      final retry = RetryInterceptor(
        policy: RetryPolicy(
          baseDelay: Duration.zero,
          useJitter: false,
          safeMethods: {'GET', 'POST'},
        ),
      );
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 1,
        cooldown: const Duration(hours: 1),
      );
      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: adapter,
        interceptors: retryFirst ? [retry, breaker] : [breaker, retry],
      ));
      final queue = InMemoryOfflineQueueStore();
      await queue.enqueue(_post());
      final dropped = <QueuedRequest>[];

      final report = await OfflineQueueReplayer(
        store: queue,
        client: client,
        onDeadLetter: (r, _) => dropped.add(r),
      ).replay();

      expect(adapter.sends, greaterThanOrEqualTo(1));
      expect(report.reEnqueued, 0,
          reason:
              'the request already hit the transport; resending duplicates');
      expect(dropped, hasLength(1));
    });
  }

  // Retry re-wraps a fail-fast rejection as sent:true once an earlier attempt
  // may have sent; the breaker (after it on the error side) must still see
  // through the wrapper, or a held-back request "fails" the in-flight probe.
  test('breaker does not count its own re-wrapped rejection as a failure',
      () async {
    final breaker = CircuitBreakerInterceptor(
      failureThreshold: 1,
      cooldown: const Duration(milliseconds: 200),
    );
    final retry = RetryInterceptor(
      policy: RetryPolicy(
        maxAttempts: 2,
        baseDelay: Duration.zero,
        useJitter: false,
        safeMethods: {'GET', 'POST'},
      ),
    );
    InterceptedRequest req() => InterceptedRequest(
          method: 'POST',
          endpoint: 'https://api.example.com/todos',
          headers: {},
          options: const RequestOptions(),
        );

    await breaker.onError(req(), const NetworkError('down')); // trips open
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(await breaker.onRequest(req()), isA<ProceedResult>()); // probe
    expect(breaker.stateFor('api.example.com'), CircuitState.halfOpen);

    // A second request: attempt 1 failed ambiguously, attempt 2 is held back.
    final first = await retry.onError(req(), const NetworkError('reset'));
    final second = (first as ProceedResult).request;
    final rejected = await breaker.onRequest(second) as RejectResult;
    final wrapped = await retry.onError(second, rejected.error) as RejectResult;
    expect((wrapped.error as NetworkError).sent, isTrue);

    await breaker.onError(second, wrapped.error);
    expect(breaker.stateFor('api.example.com'), CircuitState.halfOpen);
  });
}
