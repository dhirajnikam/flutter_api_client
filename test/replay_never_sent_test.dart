// A request rejected before it left the device (circuit breaker fail-fast) is
// not the ambiguous "may have reached the server" case, so an atMostOnce write
// must be kept, not dead-lettered, and must not burn a replay attempt.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// Fake clock for circuit-breaker cooldowns, so tests need not sleep.
var _clock = DateTime(2026);

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

// --- Helpers for the adversarial groups below ---
class _GatedAdapter implements HttpAdapter {
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

QueuedRequest _queued(String id,
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

ApiClient _gatedClient(_GatedAdapter a, List<Interceptor> i) =>
    ApiClient(ApiClientConfig(
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

class _ScriptAdapter implements HttpAdapter {
  final List<Object> script;
  final seen = <Map<String, String>>[];
  int sends = 0;
  _ScriptAdapter(this.script);
  @override
  Future<AdapterResponse> send(AdapterRequest r) async {
    seen.add(Map.of(r.headers));
    final o = script[sends < script.length ? sends : script.length - 1];
    sends++;
    throw o;
  }

  @override
  void close() {}
}

ApiClient _scriptClient(_ScriptAdapter a, List<Interceptor> i) =>
    ApiClient(ApiClientConfig(
        baseUrl: 'https://x.example.com', adapter: a, interceptors: i));
RetryInterceptor _retryAll() => RetryInterceptor(
    policy: RetryPolicy(
        baseDelay: Duration.zero,
        useJitter: false,
        safeMethods: const {'GET', 'POST'}));

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
          now: () => _clock,
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
    _clock = _clock.add(const Duration(milliseconds: 300));
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
      now: () => _clock,
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
    _clock = _clock.add(const Duration(milliseconds: 250));
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

  group('adversarial: half-open probe and batch replay', () {
    test('1a half-open: probe atMostOnce fails mid-send, rest fail fast & kept',
        () async {
      final a = _GatedAdapter();
      final c = _gatedClient(a, [
        CircuitBreakerInterceptor(
          failureThreshold: 1,
          cooldown: const Duration(milliseconds: 60),
          now: () => _clock,
        ),
      ]);
      await c.get<dynamic>('trip');
      _clock = _clock.add(const Duration(milliseconds: 100));
      final q = InMemoryOfflineQueueStore();
      for (final id in ['q1', 'q2', 'q3']) {
        await q.enqueue(_queued(id));
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
      final a = _GatedAdapter();
      final c = _gatedClient(a, [
        CircuitBreakerInterceptor(
          failureThreshold: 1,
          cooldown: const Duration(milliseconds: 60),
          now: () => _clock,
        ),
      ]);
      await c.get<dynamic>('trip');
      _clock = _clock.add(const Duration(milliseconds: 100));
      a.gate = Completer<void>();
      final probe = c.get<dynamic>('probe'); // takes the probe slot
      await pumpEventQueue();
      final q = InMemoryOfflineQueueStore();
      await q.enqueue(_queued('q1'));
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
        final a = _GatedAdapter();
        final c = _gatedClient(a, [
          CircuitBreakerInterceptor(
              failureThreshold: 1, cooldown: const Duration(hours: 1)),
        ]);
        final q = InMemoryOfflineQueueStore();
        for (final id in ['q1', 'q2', 'q3']) {
          await q.enqueue(_queued(id, s: s));
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
        final a = _GatedAdapter();
        final c = _gatedClient(a, [
          CircuitBreakerInterceptor(
              failureThreshold: 1, cooldown: const Duration(hours: 1)),
        ]);
        await c.get<dynamic>('trip');
        final OfflineQueueStore q =
            peek ? InMemoryOfflineQueueStore() : _DrainStore();
        for (var i = 0; i < 100; i++) {
          await q.enqueue(_queued('q$i',
              s: i.isEven
                  ? ReplaySafety.atMostOnce
                  : ReplaySafety.atLeastOnce));
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
      final a = _GatedAdapter();
      final c = _gatedClient(a, [
        CircuitBreakerInterceptor(
            failureThreshold: 1, cooldown: const Duration(hours: 1)),
      ]);
      await c.get<dynamic>('trip');
      final q = _FlakyStore(1); // allow the seed enqueue only
      await q.enqueue(_queued('q1'));
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
      final a = _GatedAdapter();
      final c = _gatedClient(a, [
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
      final a = _GatedAdapter();
      final c = _gatedClient(a, [
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
      final a = _GatedAdapter();
      final c = _gatedClient(a, [
        _retryPost(),
        CircuitBreakerInterceptor(
            failureThreshold: 1, cooldown: const Duration(hours: 1)),
      ]);
      final q = InMemoryOfflineQueueStore();
      await q.enqueue(_queued('q1'));
      final r = await OfflineQueueReplayer(store: q, client: c).replay();
      expect(a.sends, 1);
      expect(r.deadLettered, 1,
          reason: 'atMostOnce write that reached transport must not be kept');
    });

    test('6 spoof: default NetworkError is sent:true', () async {
      expect(const NetworkError('x').sent, isTrue);
      final a = _GatedAdapter();
      final c = _gatedClient(a, []);
      final res = await c.get<dynamic>('x');
      expect((res.error as NetworkError).sent, isTrue);
    });
  });

  group('adversarial: retry header and spoofing', () {
    test('internal retry header never reaches the adapter', () async {
      final a = _ScriptAdapter([const NetworkError('x')]);
      await _scriptClient(a, [_retryAll()]).post<dynamic>('t', const {});
      expect(a.sends, greaterThan(1));
      for (final h in a.seen) {
        expect(h.keys.map((k) => k.toLowerCase()),
            isNot(contains('x-fac-retry-attempt')));
      }
    });

    test('timeout then open breaker: final error sent:true', () async {
      final a = _ScriptAdapter([const TimeoutError('t')]);
      final c = _scriptClient(a, [
        CircuitBreakerInterceptor(
            failureThreshold: 1, cooldown: const Duration(hours: 1)),
        _retryAll(),
      ]);
      final res = await c.post<dynamic>('t', const {});
      final e = res.error;
      expect(e is NetworkError ? e.sent : true, isTrue);
    });

    test('caller-spoofed header 1s/garbage does not crash or claim unsent',
        () async {
      for (final v in ['1s', 'ss', '', 's', '-3', '9' * 40, '1s1']) {
        final a = _ScriptAdapter([const NetworkError('x')]);
        final c = _scriptClient(a, [
          CircuitBreakerInterceptor(
              failureThreshold: 1, cooldown: const Duration(hours: 1)),
          _retryAll(),
        ]);
        final res = await c.post<dynamic>('t', const {},
            options: RequestOptions(headers: {'x-fac-retry-attempt': v}));
        expect(res.isSuccess, isFalse, reason: v);
      }
    });

    test('never-sent atLeastOnce does not consume attempts over many passes',
        () async {
      final a = _ScriptAdapter([const NetworkError('x')]);
      final c = _scriptClient(a, [
        CircuitBreakerInterceptor(
            failureThreshold: 1, cooldown: const Duration(hours: 1)),
      ]);
      await c.get<dynamic>('warm'); // trips breaker
      final q = InMemoryOfflineQueueStore();
      await q.enqueue(QueuedRequest(
          id: 'a',
          method: 'POST',
          endpoint: 'todos',
          headers: const {},
          body: const {},
          createdAt: DateTime(2024)));
      final rp = OfflineQueueReplayer(store: q, client: c, maxAttempts: 2);
      for (var i = 0; i < 20; i++) {
        final r = await rp.replay();
        expect(r.reEnqueued, 1);
      }
      expect((await q.peekAll()).single.attempts, 0);
    });
  });

  group('retry attempt header', () {
    InterceptedRequest withAttempt(String? v) => InterceptedRequest(
          method: 'POST',
          endpoint: 'https://api.example.com/todos',
          headers: {if (v != null) 'x-fac-retry-attempt': v},
          options: const RequestOptions(),
        );
    final retry = RetryInterceptor(
      policy: RetryPolicy(
        baseDelay: Duration.zero,
        useJitter: false,
        safeMethods: {'POST'},
      ),
    );

    test('malformed values read as a first, unsent attempt', () async {
      for (final v in ['1s1', 'ss', '-3', '', 's', '0', ' 2', '9' * 40]) {
        final r = await retry.onError(
            withAttempt(v), const NetworkError('x', sent: false));
        expect(r, isA<ProceedResult>(), reason: v);
        expect((r as ProceedResult).request.headers['x-fac-retry-attempt'], '2',
            reason: v);
      }
    });

    test('well-formed values keep their count and sent marker', () async {
      final a = await retry.onError(
          withAttempt('2s'), const NetworkError('x', sent: false));
      expect((a as ProceedResult).request.headers['x-fac-retry-attempt'], '3s');
      final b = await retry.onError(
          withAttempt('3'), const NetworkError('x', sent: false));
      expect(b, isA<RejectResult>(), reason: 'attempts exhausted');
    });

    test('re-wrapped error keeps the transport cause one hop away', () async {
      final socket = Exception('connection refused');
      final r = await retry.onError(withAttempt('3s'),
          NetworkError('refused', cause: socket, sent: false));
      final e = (r as RejectResult).error as NetworkError;
      expect(e.sent, isTrue, reason: 'an earlier attempt may have sent');
      expect(e.cause, same(socket));
    });
  });

  group('neverSentMaxAge', () {
    Future<(OfflineMutations, Map<String, String>)>
        queuedBehindOpenBreaker() async {
      final db = <String, String>{};
      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: _DownAdapter(const NetworkError('down')),
        interceptors: [
          CircuitBreakerInterceptor(
              failureThreshold: 1, cooldown: const Duration(hours: 1)),
        ],
      ));
      final m =
          OfflineMutations(client: client, store: InMemoryOfflineQueueStore());
      await m.mutate<dynamic>('POST', 'todos', {'t': 1},
          replaySafety: ReplaySafety.atMostOnce,
          apply: () async => db['t1'] = 'pending',
          rollback: () async => db.remove('t1'));
      return (m, db);
    }

    test('default keeps a never-sent write queued', () async {
      final (m, db) = await queuedBehindOpenBreaker();
      final r = await m.buildReplayer().replay();
      expect(r.reEnqueued, 1);
      expect(db['t1'], 'pending');
    });

    test('expired never-sent write is dead-lettered and rolled back', () async {
      final (m, db) = await queuedBehindOpenBreaker();
      final r = await m.buildReplayer(neverSentMaxAge: Duration.zero).replay();
      expect(r.deadLettered, 1);
      expect(await m.store.length, 0);
      expect(db.containsKey('t1'), isFalse, reason: 'rollback ran');
    });

    test('a young never-sent write is still kept', () async {
      final (m, db) = await queuedBehindOpenBreaker();
      final r = await m
          .buildReplayer(neverSentMaxAge: const Duration(days: 1))
          .replay();
      expect(r.reEnqueued, 1);
      expect(db['t1'], 'pending');
    });
  });
}
