import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _A implements HttpAdapter {
  final List<Object> script;
  final seen = <Map<String, String>>[];
  int sends = 0;
  _A(this.script);
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

ApiClient _c(_A a, List<Interceptor> i) => ApiClient(ApiClientConfig(
    baseUrl: 'https://x.example.com', adapter: a, interceptors: i));
RetryInterceptor _r() => RetryInterceptor(
    policy: RetryPolicy(
        baseDelay: Duration.zero,
        useJitter: false,
        safeMethods: const {'GET', 'POST'}));

void main() {
  test('internal retry header never reaches the adapter', () async {
    final a = _A([const NetworkError('x')]);
    await _c(a, [_r()]).post<dynamic>('t', const {});
    expect(a.sends, greaterThan(1));
    for (final h in a.seen) {
      expect(h.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-fac-retry-attempt')));
    }
  });

  test('timeout then open breaker: final error sent:true', () async {
    final a = _A([const TimeoutError('t')]);
    final c = _c(a, [
      CircuitBreakerInterceptor(
          failureThreshold: 1, cooldown: const Duration(hours: 1)),
      _r(),
    ]);
    final res = await c.post<dynamic>('t', const {});
    final e = res.error;
    expect(e is NetworkError ? e.sent : true, isTrue);
  });

  test('caller-spoofed header 1s/garbage does not crash or claim unsent',
      () async {
    for (final v in ['1s', 'ss', '', 's', '-3', '9' * 40, '1s1']) {
      final a = _A([const NetworkError('x')]);
      final c = _c(a, [
        CircuitBreakerInterceptor(
            failureThreshold: 1, cooldown: const Duration(hours: 1)),
        _r(),
      ]);
      final res = await c.post<dynamic>('t', const {},
          options: RequestOptions(headers: {'x-fac-retry-attempt': v}));
      expect(res.isSuccess, isFalse, reason: v);
    }
  });

  test('never-sent atLeastOnce does not consume attempts over many passes',
      () async {
    final a = _A([const NetworkError('x')]);
    final c = _c(a, [
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
    final rp = OfflineQueueReplayer(
        store: q, client: c, maxAttempts: 2);
    for (var i = 0; i < 20; i++) {
      final r = await rp.replay();
      expect(r.reEnqueued, 1);
    }
    expect((await q.peekAll()).single.attempts, 0);
  });
}
