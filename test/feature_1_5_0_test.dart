import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// Fake clock for circuit-breaker cooldowns, so tests need not sleep.
var _clock = DateTime(2026);

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

Future<Box<String>> _openBox(String suffix) async {
  final dir = await Directory.systemTemp.createTemp('feature150_$suffix');
  Hive.init(dir.path);
  final box = await Hive.openBox<String>('feature150_$suffix');
  addTearDown(() async {
    if (box.isOpen) await box.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return box;
}

void main() {
  group('HiveCacheStore', () {
    test('round-trips a CacheEntry including body bytes and etag', () async {
      final store = HiveCacheStore(await _openBox('roundtrip'));
      final entry = CacheEntry(
        key: 'GET https://api.example.com/users',
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyBytes: _b('{"users":[1,2]}'),
        savedAt: DateTime(2024, 6, 1, 12),
        etag: '"v7"',
      );

      await store.write(entry);
      final back = await store.read(entry.key);

      expect(back, isNotNull);
      expect(back!.statusCode, 200);
      expect(back.headers['content-type'], 'application/json');
      expect(utf8.decode(back.bodyBytes), '{"users":[1,2]}');
      expect(back.savedAt, DateTime(2024, 6, 1, 12));
      expect(back.etag, '"v7"');
    });

    test('a corrupt record reads as a miss and is deleted', () async {
      final box = await _openBox('corrupt');
      await box.put('bad-key', 'not json at all {');
      final store = HiveCacheStore(box);

      expect(await store.read('bad-key'), isNull);
      expect(box.containsKey('bad-key'), isFalse,
          reason: 'corruption must not shadow future writes');
    });

    test('maxEntries evicts the oldest savedAt first', () async {
      final store = HiveCacheStore(await _openBox('evict'), maxEntries: 2);
      CacheEntry entry(String key, DateTime savedAt) => CacheEntry(
            key: key,
            statusCode: 200,
            headers: const {},
            bodyBytes: _b('x'),
            savedAt: savedAt,
          );

      await store.write(entry('old', DateTime(2024)));
      await store.write(entry('mid', DateTime(2024, 6)));
      await store.write(entry('new', DateTime(2025)));

      expect(await store.read('old'), isNull, reason: 'oldest evicted');
      expect(await store.read('mid'), isNotNull);
      expect(await store.read('new'), isNotNull);
    });

    test('serves offline reads through CacheInterceptor across store handoff',
        () async {
      final store = HiveCacheStore(await _openBox('offline_reads'));
      final mock = MockAdapter();
      var networkCalls = 0;
      mock.onRequest('GET', RegExp(r'/profile$'), (_) async {
        networkCalls++;
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _b('{"name":"dhiraj"}'),
        );
      });

      ApiClient buildClient() => ApiClient(ApiClientConfig.test(
            baseUrl: 'https://api.example.com',
            adapter: mock,
            interceptors: [
              CacheInterceptor(
                store: store,
                defaultPolicy:
                    CachePolicy.cacheFirst(ttl: const Duration(hours: 1)),
              ),
            ],
          ));

      final warm = await buildClient().get<dynamic>('profile');
      expect(warm.isSuccess, true);
      expect(networkCalls, 1);

      // A fresh client (simulating an app restart) reuses the persisted
      // entry without touching the network.
      final restarted = await buildClient().get<dynamic>('profile');
      expect(restarted.isSuccess, true);
      expect(restarted.data, {'name': 'dhiraj'});
      expect(networkCalls, 1, reason: 'served from the persistent cache');
    });
  });

  group('OfflineSyncManager', () {
    test('replays automatically when connectivity returns', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: '1',
          method: 'POST',
          endpoint: 'save',
          headers: const {},
          body: {'v': 1},
          createdAt: DateTime(2024)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/save$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final connectivity = StreamController<bool>();
      final reports = <OfflineReplayReport>[];
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        onlineStream: connectivity.stream,
        onReport: reports.add,
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();

      expect(reports, hasLength(1));
      expect(reports.single.succeeded, 1);
      expect(await store.length, 0);
    });

    test('schedules another pass while transient failures remain', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'flaky',
          method: 'POST',
          endpoint: 'flaky',
          headers: const {},
          createdAt: DateTime(2024)));

      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/flaky$'), (_) async {
        sends++;
        if (sends == 1) throw const NetworkError('still offline-ish');
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final connectivity = StreamController<bool>();
      final reports = <OfflineReplayReport>[];
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        onlineStream: connectivity.stream,
        retryDelay: const Duration(milliseconds: 50),
        onReport: reports.add,
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();
      expect(reports, hasLength(1));
      expect(reports.first.reEnqueued, 1);

      // The retry timer fires and the second pass delivers the request.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(reports, hasLength(2));
      expect(reports.last.succeeded, 1);
      expect(await store.length, 0);
    });

    test('going offline cancels the scheduled retry pass', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'x',
          method: 'POST',
          endpoint: 'x',
          headers: const {},
          createdAt: DateTime(2024)));

      var sends = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/x$'), (_) async {
        sends++;
        throw const NetworkError('offline');
      });
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final connectivity = StreamController<bool>();
      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        onlineStream: connectivity.stream,
        retryDelay: const Duration(milliseconds: 50),
      );
      addTearDown(() async {
        await sync.dispose();
        await connectivity.close();
      });

      sync.start();
      connectivity.add(true);
      await pumpEventQueue();
      expect(sends, 1);

      connectivity.add(false); // cancels the pending retry
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sends, 1, reason: 'no retry pass while offline');
      expect(await store.length, 1, reason: 'request stays queued');
    });

    test('replayOnStart drains writes queued in a previous session', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'boot',
          method: 'POST',
          endpoint: 'boot',
          headers: const {},
          createdAt: DateTime(2024)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/boot$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      final sync = OfflineSyncManager(
        replayer: OfflineQueueReplayer(store: store, client: client),
        replayOnStart: true,
      );
      addTearDown(sync.dispose);

      sync.start();
      await pumpEventQueue();
      expect(await store.length, 0);
    });
  });

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
          reason: 'the probe token is internal');
    });

    test('a forged probe token does not bypass the half-open hold-back',
        () async {
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 1,
        cooldown: const Duration(milliseconds: 30),
        now: () => _clock,
      );
      InterceptedRequest req([Map<String, String>? h]) => InterceptedRequest(
            method: 'GET',
            endpoint: 'https://api.example.com/x',
            headers: {...?h},
            options: const RequestOptions(),
          );

      await breaker.onError(req(), const NetworkError('down'));
      _clock = _clock.add(const Duration(milliseconds: 60));
      final probe = req();
      expect(await breaker.onRequest(probe), isA<ProceedResult>());
      expect(breaker.stateFor('api.example.com'), CircuitState.halfOpen);

      for (final guess in ['', '0', '1', '2', '3']) {
        expect(await breaker.onRequest(req({'X-FAC-Circuit-Probe': guess})),
            isA<RejectResult>(),
            reason: 'guess "$guess" must be held back');
      }
      // The real probe's retry (a copy carrying its token) still goes through.
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
      InterceptedRequest req([Map<String, String>? h]) => InterceptedRequest(
            method: 'GET',
            endpoint: 'https://api.example.com/x',
            headers: {...?h},
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

      // Stale failures (no token, or a forged one) do not reopen it.
      await breaker.onError(straggler, const NetworkError('late'));
      await breaker.onResponse(
          req({'x-fac-circuit-probe': 'forged'}), status(503));
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

    test('admitting a probe replaces a caller-supplied mixed-case token',
        () async {
      final breaker = CircuitBreakerInterceptor(
        failureThreshold: 1,
        cooldown: const Duration(seconds: 1),
        now: () => _clock,
      );
      InterceptedRequest req([Map<String, String>? h]) => InterceptedRequest(
            method: 'GET',
            endpoint: 'https://api.example.com/x',
            headers: {...?h},
            options: const RequestOptions(),
          );
      await breaker.onError(req(), const NetworkError('down'));
      _clock = _clock.add(const Duration(seconds: 2));
      final probe = req({'X-Fac-Circuit-Probe': 'abc'});
      await breaker.onRequest(probe);
      final keys = probe.headers.keys
          .where((k) => k.toLowerCase() == 'x-fac-circuit-probe');
      expect(keys, ['x-fac-circuit-probe']);
      expect(probe.headers['x-fac-circuit-probe'], isNot('abc'));
    });
  });

  group('ApiResult ergonomics', () {
    const ok = Success<int>(2, statusCode: 200);
    const bad = Failure<int>(HttpError('nope', statusCode: 400));

    test('flatMap chains success and short-circuits failure', () {
      final chained =
          ok.flatMap((v) => Success<String>('v$v', statusCode: 200));
      expect(chained.data, 'v2');

      final rejected =
          ok.flatMap<String>((v) => const Failure(ParseError('bad shape')));
      expect(rejected.error, isA<ParseError>());

      var called = false;
      final skipped = bad.flatMap<String>((v) {
        called = true;
        return Success<String>('$v', statusCode: 200);
      });
      expect(called, isFalse);
      expect(skipped.error, isA<HttpError>());
      expect(skipped.statusCode, 400, reason: 'failure status carried over');
    });

    test('mapError transforms only the failure branch', () {
      final wrapped = bad
          .mapError((e) => UnknownError('user-facing: ${e.message}', cause: e));
      expect(wrapped.errorMessage, 'user-facing: nope');
      expect(ok.mapError((e) => const UnknownError('x')).data, 2);
    });

    test('getOrElse returns data or the fallback', () {
      expect(ok.getOrElse((_) => -1), 2);
      expect(bad.getOrElse((e) => -1), -1);
    });

    test('onSuccess/onFailure tap the right branch and chain', () {
      final log = <String>[];
      final result = ok
          .onSuccess((v) => log.add('ok:$v'))
          .onFailure((e) => log.add('err'));
      expect(log, ['ok:2']);
      expect(result.data, 2, reason: 'taps return the result unchanged');

      log.clear();
      bad.onSuccess((v) => log.add('ok')).onFailure((e) => log.add('err'));
      expect(log, ['err']);
    });
  });
}
