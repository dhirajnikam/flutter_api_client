// Adversarial tests for the "never sent" replay change.

import 'dart:async';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpAdapter {
  int sends = 0;
  Completer<void>? gate;
  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    sends++;
    if (gate != null) await gate!.future;
    throw const NetworkError('down');
  }

  @override
  void close() {}
}

QueuedRequest _q(String id,
        {ReplaySafety s = ReplaySafety.atMostOnce, String m = 'POST'}) =>
    QueuedRequest(
      id: id,
      method: m,
      endpoint: 'todos',
      headers: const {},
      body: const {'t': 1},
      createdAt: DateTime(2024),
      replaySafety: s,
    );

ApiClient _client(_Adapter a, List<Interceptor> i) => ApiClient(ApiClientConfig(
    baseUrl: 'https://api.example.com', adapter: a, interceptors: i));

/// Peekable store whose enqueue throws after [okEnqueues] successes.
class _FlakyStore extends InMemoryOfflineQueueStore {
  _FlakyStore(this.okEnqueues);
  int okEnqueues;
  @override
  Future<void> enqueue(QueuedRequest r) async {
    if (okEnqueues-- <= 0) throw StateError('disk full');
    return super.enqueue(r);
  }
}

/// Drain-only (non peekable) store.
class _DrainStore implements OfflineQueueStore {
  final items = <QueuedRequest>[];
  @override
  Future<void> enqueue(QueuedRequest r) async => items.add(r);
  @override
  Future<List<QueuedRequest>> drain() async {
    final o = List<QueuedRequest>.from(items)..sort(compareQueuedRequests);
    items.clear();
    return o;
  }

  @override
  Future<void> remove(String id) async => items.removeWhere((r) => r.id == id);
  @override
  Future<int> get length async => items.length;
}

RetryInterceptor _retryPost() => RetryInterceptor(
    policy: RetryPolicy(
        baseDelay: Duration.zero,
        useJitter: false,
        safeMethods: const {'GET', 'POST'}));

void main() {
  test('1a half-open: probe atMostOnce fails mid-send, rest fail fast & kept',
      () async {
    final a = _Adapter();
    final c = _client(a, [
      CircuitBreakerInterceptor(
          failureThreshold: 1, cooldown: const Duration(milliseconds: 60)),
    ]);
    await c.get<dynamic>('trip');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final q = InMemoryOfflineQueueStore();
    for (final id in ['q1', 'q2', 'q3']) {
      await q.enqueue(_q(id));
    }
    final dead = <String>[];
    final r = await OfflineQueueReplayer(
        store: q, client: c, onDeadLetter: (x, _) => dead.add(x.id)).replay();
    expect(a.sends, 2, reason: 'trip + exactly one probe');
    expect(r.deadLettered, 1);
    expect(r.reEnqueued, 2);
    expect(dead, ['q1']);
    expect((await q.peekAll()).map((e) => e.id).toSet(), {'q2', 'q3'});
  });

  test('1b half-open with probe in flight: replayed writes rejected and kept',
      () async {
    final a = _Adapter();
    final c = _client(a, [
      CircuitBreakerInterceptor(
          failureThreshold: 1, cooldown: const Duration(milliseconds: 60)),
    ]);
    await c.get<dynamic>('trip');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    a.gate = Completer<void>();
    final probe = c.get<dynamic>('probe'); // takes the probe slot
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final q = InMemoryOfflineQueueStore();
    await q.enqueue(_q('q1'));
    final r = await OfflineQueueReplayer(store: q, client: c).replay();
    expect(r.reEnqueued, 1);
    expect(r.deadLettered, 0);
    expect(a.sends, 2);
    a.gate!.complete();
    await probe;
  });

  test('2 mid-batch trip: counts add up (atMostOnce and atLeastOnce)',
      () async {
    for (final s in ReplaySafety.values) {
      final a = _Adapter();
      final c = _client(a, [
        CircuitBreakerInterceptor(
            failureThreshold: 1, cooldown: const Duration(hours: 1)),
      ]);
      final q = InMemoryOfflineQueueStore();
      for (final id in ['q1', 'q2', 'q3']) {
        await q.enqueue(_q(id, s: s));
      }
      final outcomes = <String, ReplayOutcome>{};
      final r = await OfflineQueueReplayer(
          store: q,
          client: c,
          onOutcome: (x, o) => outcomes[x.id] = o).replay();
      expect(a.sends, 1, reason: '$s only the first reaches transport');
      expect(r.succeeded + r.reEnqueued + r.deadLettered, 3);
      expect(await q.length, r.reEnqueued);
      if (s == ReplaySafety.atMostOnce) {
        expect(r.deadLettered, 1);
        expect(r.reEnqueued, 2);
      } else {
        expect(r.reEnqueued, 3);
        final left = await q.peekAll();
        expect(left.firstWhere((e) => e.id == 'q1').attempts, 1);
        expect(left.firstWhere((e) => e.id == 'q2').attempts, 0);
      }
      expect(outcomes['q2'], ReplayOutcome.reEnqueued);
    }
  });

  test('3 one pass sends each request at most once; no hang (100 reqs)',
      () async {
    for (final peek in [true, false]) {
      final a = _Adapter();
      final c = _client(a, [
        CircuitBreakerInterceptor(
            failureThreshold: 1, cooldown: const Duration(hours: 1)),
      ]);
      await c.get<dynamic>('trip');
      final OfflineQueueStore q =
          peek ? InMemoryOfflineQueueStore() : _DrainStore();
      for (var i = 0; i < 100; i++) {
        await q.enqueue(_q('q$i',
            s: i.isEven ? ReplaySafety.atMostOnce : ReplaySafety.atLeastOnce));
      }
      final r = await OfflineQueueReplayer(store: q, client: c)
          .replay()
          .timeout(const Duration(seconds: 10));
      expect(r.reEnqueued, 100);
      expect(a.sends, 1);
      expect(await q.length, 100);
      for (var i = 0; i < 10; i++) {
        await OfflineQueueReplayer(store: q, client: c, maxAttempts: 1)
            .replay();
      }
      expect(await q.length, 100, reason: 'unbounded retention while open');
    }
  });

  test('4 settle(keep) throws for detached atMostOnce never-sent: reported',
      () async {
    final a = _Adapter();
    final c = _client(a, [
      CircuitBreakerInterceptor(
          failureThreshold: 1, cooldown: const Duration(hours: 1)),
    ]);
    await c.get<dynamic>('trip');
    final q = _FlakyStore(1); // allow the seed enqueue only
    await q.enqueue(_q('q1'));
    final dead = <String>[];
    final deadErr = <ApiException?>[];
    final outcomes = <ReplayOutcome>[];
    final r = await OfflineQueueReplayer(
      store: q,
      client: c,
      onDeadLetter: (x, e) {
        dead.add(x.id);
        deadErr.add(e);
      },
      onOutcome: (_, o) => outcomes.add(o),
    ).replay();
    expect(r.deadLettered, 1);
    expect(dead, ['q1']);
    expect(outcomes, [ReplayOutcome.deadLettered]);
    expect(await q.length, 0);
  });

  test('5a Retry BEFORE breaker, POST retryable: sent flag must stay true',
      () async {
    final a = _Adapter();
    final c = _client(a, [
      _retryPost(),
      CircuitBreakerInterceptor(
          failureThreshold: 1, cooldown: const Duration(hours: 1)),
    ]);
    final res = await c.post<dynamic>('todos', const {'t': 1});
    expect(a.sends, 1, reason: 'first attempt really went to transport');
    expect((res.error as NetworkError).sent, isTrue,
        reason: 'final error must still say it may have been sent');
  });

  test('5b documented order [breaker, retry]: sent:true preserved', () async {
    final a = _Adapter();
    final c = _client(a, [
      CircuitBreakerInterceptor(
          failureThreshold: 1, cooldown: const Duration(hours: 1)),
      _retryPost(),
    ]);
    final res = await c.post<dynamic>('todos', const {'t': 1});
    expect(a.sends, greaterThanOrEqualTo(1));
    expect((res.error as NetworkError).sent, isTrue);
  });

  test('5c replayer with 5a ordering: atMostOnce that was sent is kept (dup)',
      () async {
    final a = _Adapter();
    final c = _client(a, [
      _retryPost(),
      CircuitBreakerInterceptor(
          failureThreshold: 1, cooldown: const Duration(hours: 1)),
    ]);
    final q = InMemoryOfflineQueueStore();
    await q.enqueue(_q('q1'));
    final r = await OfflineQueueReplayer(store: q, client: c).replay();
    expect(a.sends, 1);
    expect(r.deadLettered, 1,
        reason: 'atMostOnce write that reached transport must not be kept');
  });

  test('6 spoof: default NetworkError is sent:true', () async {
    expect(const NetworkError('x').sent, isTrue);
    final a = _Adapter();
    final c = _client(a, []);
    final res = await c.get<dynamic>('x');
    expect((res.error as NetworkError).sent, isTrue);
  });
}
