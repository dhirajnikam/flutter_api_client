// A request rejected before it left the device (circuit breaker fail-fast) is
// not the ambiguous "may have reached the server" case, so an atMostOnce write
// must be kept, not dead-lettered, and must not burn a replay attempt.

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
