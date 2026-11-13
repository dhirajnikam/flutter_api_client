import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake clock for circuit-breaker cooldowns, so tests need not sleep.
var _clock = DateTime(2026);

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('CircuitBreakerInterceptor', () {
    ApiClient buildClient(
            MockAdapter mock, CircuitBreakerInterceptor breaker) =>
        ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [breaker],
        ));

    test('opens after the failure threshold and fails fast', () async {
      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/down$'), (_) async {
        sends++;
        throw const NetworkError('connection refused');
      });
      final states = <CircuitState>[];
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 3,
        cooldown: const Duration(minutes: 5),
        onStateChange: (_, s) => states.add(s),
      );
      final client = buildClient(mock, breaker);

      for (var i = 0; i < 3; i++) {
        await client.get<dynamic>('down');
      }
      expect(breaker.stateFor('api.example.com'), CircuitState.open);
      expect(states, [CircuitState.open]);

      final fast = await client.get<dynamic>('down');
      expect(fast.error, isA<NetworkError>());
      expect(fast.errorMessage, contains('Circuit breaker open'));
      expect(sends, 3, reason: 'the fourth request never hit transport');
    });

    test('a successful response resets the failure count', () async {
      var call = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/mixed$'), (_) async {
        call++;
        if (call.isOdd) throw const NetworkError('flaky');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final breaker = CircuitBreakerInterceptor(failureThreshold: 2);
      final client = buildClient(mock, breaker);

      // fail, success, fail, success — never two consecutive failures.
      for (var i = 0; i < 4; i++) {
        await client.get<dynamic>('mixed');
      }
      expect(breaker.stateFor('api.example.com'), CircuitState.closed);
    });

    test('half-open probe closes the circuit on success', () async {
      var reachable = false;
      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/recovering$'), (_) async {
        sends++;
        if (!reachable) throw const NetworkError('down');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 2,
        cooldown: const Duration(milliseconds: 30),
        now: () => _clock,
      );
      final client = buildClient(mock, breaker);

      await client.get<dynamic>('recovering');
      await client.get<dynamic>('recovering');
      expect(breaker.stateFor('api.example.com'), CircuitState.open);

      reachable = true;
      _clock = _clock.add(const Duration(milliseconds: 60));
      final probe = await client.get<dynamic>('recovering');
      expect(probe.isSuccess, true);
      expect(breaker.stateFor('api.example.com'), CircuitState.closed);
      expect(sends, 3);
    });

    test('4xx responses do not trip the circuit', () async {
      final mock = MockAdapter();
      mock.on('GET', RegExp(r'/forbidden$'),
          statusCode: 403, body: {'error': 'no'});
      final breaker = CircuitBreakerInterceptor(failureThreshold: 2);
      final client = buildClient(mock, breaker);

      for (var i = 0; i < 5; i++) {
        await client.get<dynamic>('forbidden');
      }
      expect(breaker.stateFor('api.example.com'), CircuitState.closed,
          reason: 'a 403 proves the origin is reachable');
    });

    test('5xx responses count as failures', () async {
      final mock = MockAdapter();
      mock.on('GET', RegExp(r'/erroring$'),
          statusCode: 503, body: {'error': 'unavailable'});
      final breaker = CircuitBreakerInterceptor(failureThreshold: 2);
      final client = buildClient(mock, breaker);

      await client.get<dynamic>('erroring');
      await client.get<dynamic>('erroring');
      expect(breaker.stateFor('api.example.com'), CircuitState.open);
    });

    test('circuits are isolated per host', () async {
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/ping$'), (req) async {
        if (req.url.host == 'down.example.com') {
          throw const NetworkError('down');
        }
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final breaker = CircuitBreakerInterceptor(failureThreshold: 1);
      final client = buildClient(mock, breaker);

      await client.get<dynamic>('ping',
          options: const RequestOptions(
              baseUrlOverride: 'https://down.example.com'));
      expect(breaker.stateFor('down.example.com'), CircuitState.open);

      final healthy = await client.get<dynamic>('ping');
      expect(healthy.isSuccess, true,
          reason: 'the default host circuit is unaffected');
      expect(breaker.stateFor('api.example.com'), CircuitState.closed);
    });

    // With [breaker, retry] a failed probe is retried before the breaker sees
    // it. The probe must still settle the circuit: open while down, closed
    // once the origin recovers — never wedged half-open.
    test('a probe lost to retries does not wedge the circuit half-open',
        () async {
      var reachable = false;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/wedge$'), (_) async {
        if (!reachable) throw const NetworkError('down');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 1,
        cooldown: const Duration(milliseconds: 30),
        now: () => _clock,
      );
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          breaker,
          RetryInterceptor(
              policy: RetryPolicy(baseDelay: Duration.zero, useJitter: false)),
        ],
      ));

      await client.get<dynamic>('wedge');
      expect(breaker.stateFor('api.example.com'), CircuitState.open);
      _clock = _clock.add(const Duration(milliseconds: 60));
      await client.get<dynamic>('wedge'); // probe and its retries fail
      expect(breaker.stateFor('api.example.com'), CircuitState.open);

      reachable = true;
      _clock = _clock.add(const Duration(milliseconds: 60));
      final res = await client.get<dynamic>('wedge');
      expect(res.isSuccess, isTrue);
      expect(breaker.stateFor('api.example.com'), CircuitState.closed);
    });

    test('a failed probe reopens the circuit under [breaker, retry]', () async {
      var calls = 0;
      final sentHeaders = <Map<String, String>>[];
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/probe$'), (r) async {
        calls++;
        sentHeaders.add(r.headers);
        throw const NetworkError('down');
      });
      final states = <CircuitState>[];
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 1,
        cooldown: const Duration(milliseconds: 30),
        now: () => _clock,
        onStateChange: (_, s) => states.add(s),
      );
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          breaker,
          RetryInterceptor(
              policy: RetryPolicy(baseDelay: Duration.zero, useJitter: false)),
        ],
      ));

      await client.get<dynamic>('probe'); // trips open after its retries
      expect(breaker.stateFor('api.example.com'), CircuitState.open);
      _clock = _clock.add(const Duration(milliseconds: 60));
      calls = 0;
      sentHeaders.clear();

      final res = await client.get<dynamic>('probe');
      expect(res.isFailure, isTrue);
      expect(calls, 3, reason: "the probe's retries reach the transport");
      expect(breaker.stateFor('api.example.com'), CircuitState.open);
      expect(states,
          [CircuitState.open, CircuitState.halfOpen, CircuitState.open]);
      expect(
          sentHeaders
              .expand((h) => h.keys)
              .where((k) => k.toLowerCase().startsWith('x-fac-')),
          isEmpty,
          reason: 'no internal header reaches the wire');
    });

    test('half-open holds back every request but the probe and its retries',
        () async {
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 1,
        cooldown: const Duration(milliseconds: 30),
        now: () => _clock,
      );
      InterceptedRequest req() => InterceptedRequest(
            method: 'GET',
            endpoint: 'https://api.example.com/x',
            headers: {},
            options: const RequestOptions(),
          );

      await breaker.onError(req(), const NetworkError('down'));
      _clock = _clock.add(const Duration(milliseconds: 60));
      final probe = req();
      expect(await breaker.onRequest(probe), isA<ProceedResult>());
      expect(breaker.stateFor('api.example.com'), CircuitState.halfOpen);

      expect(await breaker.onRequest(req()), isA<RejectResult>(),
          reason: 'only one probe may be in flight');
      // The probe's own retry (a copy of it) still goes through.
      expect(await breaker.onRequest(probe.copy()), isA<ProceedResult>());
    });

    // Only the admitted probe's outcome may move a circuit that is not
    // closed; a request admitted earlier that finishes late is stale.
    test('late outcomes of earlier requests do not move an open circuit',
        () async {
      final states = <CircuitState>[];
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 1,
        cooldown: const Duration(seconds: 20),
        now: () => _clock,
        onStateChange: (_, s) => states.add(s),
      );
      InterceptedRequest req() => InterceptedRequest(
            method: 'GET',
            endpoint: 'https://api.example.com/x',
            headers: {},
            options: const RequestOptions(),
          );
      AdapterResponse status(int code) => AdapterResponse(
          statusCode: code, headers: const {}, bodyBytes: Uint8List(0));

      final straggler = req();
      expect(await breaker.onRequest(straggler), isA<ProceedResult>());
      await breaker.onError(req(), const NetworkError('down')); // trips open

      // Admitted while closed, answers 200 after the circuit opened.
      await breaker.onResponse(straggler, status(200));
      expect(breaker.stateFor('api.example.com'), CircuitState.open);

      _clock = _clock.add(const Duration(seconds: 21));
      final probe = req();
      expect(await breaker.onRequest(probe), isA<ProceedResult>());

      // Stale failures (requests that are not the probe) do not reopen it.
      await breaker.onError(straggler, const NetworkError('late'));
      await breaker.onResponse(req(), status(503));
      expect(breaker.stateFor('api.example.com'), CircuitState.halfOpen);

      await breaker.onResponse(probe, status(200));
      expect(breaker.stateFor('api.example.com'), CircuitState.closed);
      expect(states,
          [CircuitState.open, CircuitState.halfOpen, CircuitState.closed]);
    });

    group('probe outcomes', () {
      InterceptedRequest req() => InterceptedRequest(
            method: 'GET',
            endpoint: 'https://api.example.com/x',
            headers: {},
            options: const RequestOptions(),
          );
      AdapterResponse status(int code, [Map<String, String>? h]) =>
          AdapterResponse(
              statusCode: code,
              headers: h ?? const {},
              bodyBytes: Uint8List(0));
      Future<CircuitBreakerInterceptor> halfOpen() async {
        final breaker = CircuitBreakerInterceptor(
            failureThreshold: 1,
            cooldown: const Duration(seconds: 10),
            now: () => _clock);
        await breaker.onError(req(), const NetworkError('down'));
        _clock = _clock.add(const Duration(seconds: 11));
        return breaker;
      }

      test('a slow probe replaced after its lease can still close it',
          () async {
        final breaker = await halfOpen();
        final slow = req();
        expect(await breaker.onRequest(slow), isA<ProceedResult>());
        _clock = _clock.add(const Duration(seconds: 11));
        expect(await breaker.onRequest(req()), isA<ProceedResult>(),
            reason: 'lease ran out: a replacement probe is admitted');
        await breaker.onResponse(slow, status(200)); // the old probe answers
        expect(breaker.stateFor('api.example.com'), CircuitState.closed);
      });

      test('a replaced probe failing late does not cut short the current one',
          () async {
        final breaker = await halfOpen();
        final old = req();
        await breaker.onRequest(old);
        _clock = _clock.add(const Duration(seconds: 11));
        final current = req();
        await breaker.onRequest(current);
        await breaker.onError(old, const NetworkError('late'));
        expect(breaker.stateFor('api.example.com'), CircuitState.halfOpen);
        expect(await breaker.onRequest(current.copy()), isA<ProceedResult>(),
            reason: "the current probe's retry still gets through");
        await breaker.onError(current, const NetworkError('down'));
        expect(breaker.stateFor('api.example.com'), CircuitState.open);
      });

      test('responses the cache served locally do not decide the circuit',
          () async {
        final breaker = await halfOpen();
        final probe = req();
        await breaker.onRequest(probe);
        await breaker.onResponse(
            probe, status(200, {'x-fac-cache-hit': 'hit'}));
        await breaker.onResponse(
            probe, status(504, {'x-fac-cache-hit': 'miss'}));
        expect(breaker.stateFor('api.example.com'), CircuitState.halfOpen);
        await breaker.onResponse(probe, status(200));
        expect(breaker.stateFor('api.example.com'), CircuitState.closed);
      });
    });
  });
}
