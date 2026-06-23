// CONCURRENCY + STATE INVARIANTS audit (work item w2). — edsger-dijkstra
//
// "Program testing can be used to show the presence of bugs, but never to show
// their absence." We therefore cannot prove correctness by tests alone. What we
// CAN do is name the invariant precisely, then construct the single execution
// that would violate it and assert the violation does not occur. Each group
// below states an invariant as a comment and the test is its falsification
// attempt.
//
// Every test that exercises coalescing/refresh/replay carries a TIMEOUT GUARD:
// a re-introduced deadlock must fail LOUDLY (a thrown StateError), never hang
// CI indefinitely. A hang is the worst failure mode — it is indistinguishable
// from progress until the wall clock runs out.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_api_client/flutter_api_client.dart';
// request_identity.dart is intentionally NOT part of the public surface (it is
// internal bookkeeping). We import the src path directly to prove the identity
// invariant without widening the public API. — edsger-dijkstra
import 'package:flutter_api_client/src/interceptors/request_identity.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// Mirrors AuthInterceptor._fingerprint so white-box tests can inject the
/// fingerprint a request would have carried for [token].
String _fp(String token) => sha256.convert(utf8.encode(token)).toString();

InterceptedRequest _req({
  String method = 'GET',
  String endpoint = '/x',
  Map<String, String>? headers,
  Object? data,
}) =>
    InterceptedRequest(
      method: method,
      endpoint: endpoint,
      headers: headers ?? <String, String>{},
      options: const RequestOptions(),
      data: data,
    );

/// A deadline wrapper. The PROOF OBLIGATION for every concurrency property is
/// "terminates AND terminates correctly". `T<R>` discharges the termination
/// half: if the future does not settle within [d], we raise rather than wait.
Future<R> within<R>(Future<R> f, {Duration d = const Duration(seconds: 4)}) => f
    .timeout(d, onTimeout: () => throw StateError('deadlock / liveness fault'));

/// TokenStorage whose getAccessToken can be made to interleave: each call
/// awaits a microtask, widening the window in which two concurrent flows can
/// observe the same pre-refresh state. Used to stress the single-flight guard.
class _SlowTokenStorage implements TokenStorage {
  _SlowTokenStorage(this._token);
  String? _token;
  int reads = 0;

  @override
  Future<String?> getAccessToken() async {
    reads++;
    await Future<void>.delayed(Duration.zero);
    return _token;
  }

  @override
  Future<void> setAccessToken(String? token) async => _token = token;
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<void> clear() async => _token = null;
}

void main() {
  // ===========================================================================
  // INVARIANT A — Auth single-flight refresh.
  //   For any set of concurrent 401s observed within one refresh generation,
  //   the user-supplied `refresh` callback is invoked AT MOST ONCE, and every
  //   waiter observes the same outcome. (No double-refresh, no lost wakeup.)
  // ===========================================================================
  group('INV-A: auth refresh is single-flight', () {
    test('N concurrent 401s trigger exactly one refresh', () async {
      var refreshCalls = 0;
      final storage = _SlowTokenStorage('OLD');
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          // A slow refresh: all concurrent callers MUST coalesce onto this one
          // future, not each start their own.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await storage.setAccessToken('FRESH');
          return true;
        },
      );

      AdapterResponse res401() => AdapterResponse(
            statusCode: 401,
            headers: const {},
            bodyBytes: Uint8List(0),
          );

      // Eight requests all went out with the SAME token fingerprint and all
      // get 401 simultaneously. The staleness guard must NOT short-circuit
      // (the stored token still equals what they used), so all eight reach
      // _refreshOnce — which must collapse to a single refresh().
      final fp = _fp('OLD');
      final futures = List.generate(8, (_) {
        final r = _req(headers: {
          'Authorization': 'Bearer OLD',
          'x-fac-auth-token-fp': fp,
        });
        return auth.onResponse(r, res401());
      });

      final results = await within(Future.wait(futures));
      // Postcondition 1: every waiter proceeds to retry.
      for (final r in results) {
        expect(r, isA<ProceedResult>());
      }
      // Postcondition 2: exactly one refresh fired for the whole cohort.
      expect(refreshCalls, 1, reason: 'single-flight: at most one refresh');
    });

    test('a second generation refreshes again (guard resets after completion)',
        () async {
      var refreshCalls = 0;
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          // Do NOT rotate the token, so the staleness guard never fires and we
          // genuinely re-enter _refreshOnce on the second generation.
          return true;
        },
      );
      final fp = _fp('OLD');
      AdapterResponse res401() => AdapterResponse(
          statusCode: 401, headers: const {}, bodyBytes: Uint8List(0));

      await within(auth.onResponse(
          _req(headers: {'x-fac-auth-token-fp': fp}), res401()));
      await within(auth.onResponse(
          _req(headers: {'x-fac-auth-token-fp': fp}), res401()));

      // Two SEQUENTIAL generations => the _inFlight latch must have cleared
      // between them (whenComplete). Liveness of the guard, not just safety.
      expect(refreshCalls, 2, reason: 'guard must reset after each generation');
    });

    test('a failing refresh does not wedge _inFlight forever', () async {
      var refreshCalls = 0;
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          throw const NetworkError('refresh endpoint down');
        },
      );
      final fp = _fp('OLD');
      AdapterResponse res401() => AdapterResponse(
          statusCode: 401, headers: const {}, bodyBytes: Uint8List(0));

      // First generation: refresh throws -> _refreshOnce catches -> false ->
      // ResolveResult(401). Crucially whenComplete must still clear _inFlight.
      final r1 = await within(auth.onResponse(
          _req(headers: {'x-fac-auth-token-fp': fp}), res401()));
      expect(r1, isA<ResolveResult>(), reason: 'failed refresh surfaces 401');

      // Second generation must be able to TRY AGAIN — proof the latch released
      // even on the exceptional path.
      final r2 = await within(auth.onResponse(
          _req(headers: {'x-fac-auth-token-fp': fp}), res401()));
      expect(r2, isA<ResolveResult>());
      expect(refreshCalls, 2, reason: 'latch released on the failure path too');
    });

    test('staleness guard prevents double-refresh when token already rotated',
        () async {
      // INV-A corollary: if the stored token already differs from the one the
      // request used, NO refresh fires — we retry with the fresh token. This is
      // the no-double-spend property for refresh tokens.
      var refreshCalls = 0;
      final storage = MemoryTokenStorage(accessToken: 'ROTATED');
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          return true;
        },
      );
      final r = await within(auth.onResponse(
        _req(headers: {
          'Authorization': 'Bearer OLD',
          'x-fac-auth-token-fp': _fp('OLD'),
        }),
        AdapterResponse(
            statusCode: 401, headers: const {}, bodyBytes: Uint8List(0)),
      ));
      expect(r, isA<ProceedResult>());
      expect(refreshCalls, 0, reason: 'rotated token => no redundant refresh');
    });
  });

  // ===========================================================================
  // INVARIANT B — Dedup coalescing.
  //   At most one network request per identity key is in flight. Followers
  //   either (a) share the leader's buffered response, or (b) fall back to
  //   their own request, but NEVER hang past waitTimeout and NEVER deadlock the
  //   leader. The owner of the key (re-entry on retry) always proceeds.
  // ===========================================================================
  group('INV-B: dedup leader/follower coalescing', () {
    test('a single leader serves many followers — exactly one network hit',
        () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/coalesce$'), (_) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _b('"shared"'),
        );
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          DedupInterceptor(waitTimeout: const Duration(seconds: 5))
        ],
      ));

      final results = await within(Future.wait([
        for (var i = 0; i < 10; i++) client.get<dynamic>('coalesce'),
      ]));
      for (final r in results) {
        expect(r.statusCode, 200);
      }
      expect(hits, 1,
          reason: 'ten identical concurrent GETs => one network hit');
    });

    test('re-entry guard: leader proceeds through retry restart (no self-wait)',
        () async {
      // The candidate deadlock: a retry copies headers (including the dedup key
      // header) and RESTARTS the chain. If dedup did not recognise itself as
      // the key owner, the leader would await its own (still-open) completer
      // and deadlock. Drive it through the real chain.
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        hits++;
        if (hits == 1) {
          return AdapterResponse(
              statusCode: 503, headers: const {}, bodyBytes: _b('busy'));
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _b('"ok"'),
        );
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          DedupInterceptor(waitTimeout: const Duration(seconds: 5)),
          RetryInterceptor(
            policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1)),
          ),
        ],
      ));
      final results = await within(Future.wait([
        client.get<dynamic>('flaky'),
        client.get<dynamic>('flaky'),
        client.get<dynamic>('flaky'),
      ]));
      for (final r in results) {
        expect(r.statusCode, 200);
      }
      // One leader, one retried network round-trip; followers coalesced.
      expect(hits, 2, reason: 'leader retried once; followers did not re-hit');
    });

    test('follower is released, not parked, when the leader errors', () async {
      // If the leader fails, every coalesced follower shares the failure
      // IMMEDIATELY (completeError) — they are not left to time out.
      final dedup = DedupInterceptor(waitTimeout: const Duration(seconds: 10));
      final leader = _req(endpoint: '/e');
      final lp = (await dedup.onRequest(leader) as ProceedResult).request;
      final followerFuture = dedup.onRequest(_req(endpoint: '/e'));

      // Attach the expectation listener BEFORE the leader errors, so the
      // follower's rejected future is observed the instant it completes (the
      // shared failure must propagate to the follower as a thrown
      // ApiException, promptly — never park for waitTimeout).
      final expectation = expectLater(
        within(followerFuture, d: const Duration(seconds: 2)),
        throwsA(isA<NetworkError>()),
      );

      // Leader fails.
      await dedup.onError(lp, const NetworkError('down'));
      await expectation;
    });

    test('streaming leader releases followers immediately (not after timeout)',
        () async {
      final dedup = DedupInterceptor(waitTimeout: const Duration(seconds: 10));
      final lp = (await dedup.onRequest(_req(endpoint: '/s')) as ProceedResult)
          .request;
      final followerFuture = dedup.onRequest(_req(endpoint: '/s'));
      await dedup.onResponse(
        lp,
        AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List(0),
          bodyStream: const Stream<List<int>>.empty(),
        ),
      );
      final fr = await within(followerFuture, d: const Duration(seconds: 2));
      expect(fr, isA<ProceedResult>(),
          reason: 'unshareable stream => follower runs its own request');
    });

    test('map invariant: completer is removed on BOTH success and error paths',
        () async {
      // No leak: after the leader settles, the key must be absent so the NEXT
      // request for the same identity becomes a fresh leader (not a follower
      // waiting on a dead completer).
      final dedup = DedupInterceptor();
      // success path
      final l1 = (await dedup.onRequest(_req(endpoint: '/k')) as ProceedResult)
          .request;
      await dedup.onResponse(
          l1,
          AdapterResponse(
              statusCode: 200, headers: const {}, bodyBytes: _b('a')));
      // A subsequent request must itself become a leader (ProceedResult), which
      // is only possible if the key was removed.
      final again = await dedup.onRequest(_req(endpoint: '/k'));
      expect(again, isA<ProceedResult>(), reason: 'key cleared after success');

      // error path
      final l2 = (await dedup.onRequest(_req(endpoint: '/m')) as ProceedResult)
          .request;
      await dedup.onError(l2, const TimeoutError('x'));
      final again2 = await dedup.onRequest(_req(endpoint: '/m'));
      expect(again2, isA<ProceedResult>(), reason: 'key cleared after error');
    });

    test('a leaderless error does NOT leak an unhandled async exception',
        () async {
      // REGRESSION (bug fixed in w2): the leader's completer is observed only
      // by followers. A leader that errors (or streams) while it has ZERO
      // followers used to complete an unobserved error future, which Dart
      // surfaces as an *unhandled asynchronous error* in the surrounding zone —
      // a crash under `runZonedGuarded`. The interceptor must attach its own
      // observer so the error is always consumed. We assert nothing escapes to
      // the zone's uncaught handler.
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final dedup = DedupInterceptor();

        // Case 1: error path, no follower.
        final l1 =
            (await dedup.onRequest(_req(endpoint: '/x1')) as ProceedResult)
                .request;
        await dedup.onError(l1, const NetworkError('boom'));

        // Case 2: streaming (unshareable) path, no follower.
        final l2 =
            (await dedup.onRequest(_req(endpoint: '/x2')) as ProceedResult)
                .request;
        await dedup.onResponse(
          l2,
          AdapterResponse(
            statusCode: 200,
            headers: const {},
            bodyBytes: Uint8List(0),
            bodyStream: const Stream<List<int>>.empty(),
          ),
        );

        // Let any unobserved-error microtask fire.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }, (e, st) => uncaught.add(e));

      expect(uncaught, isEmpty,
          reason:
              'leaderless completer error must be self-observed, not leaked');
    });

    test('non-GET methods bypass dedup entirely (no coalescing of mutations)',
        () async {
      // Coalescing two POSTs would be a correctness disaster (one write lost).
      // The method gate is the invariant that prevents it.
      final dedup = DedupInterceptor();
      final p1 = await dedup.onRequest(_req(method: 'POST', endpoint: '/w'));
      final p2 = await dedup.onRequest(_req(method: 'POST', endpoint: '/w'));
      expect(p1, isA<ProceedResult>());
      expect(p2, isA<ProceedResult>(),
          reason: 'two POSTs must both proceed — never coalesce');
    });
  });

  // ===========================================================================
  // INVARIANT C — request identity key.
  //   The dedup/cache key is INDEPENDENT of internal bookkeeping headers
  //   (retry attempt, dedup key, auth fp, etc.) and of `if-none-match`. If it
  //   were not, a retry (which mutates x-fac-retry-attempt) would compute a
  //   DIFFERENT key and defeat both the re-entry guard and cache revalidation.
  // ===========================================================================
  group('INV-C: identity key ignores internal + revalidation headers', () {
    test('attempt/dedup/auth headers do not perturb the key', () {
      final bare = requestIdentityKey(_req(endpoint: '/r'));
      final withInternals = requestIdentityKey(_req(endpoint: '/r', headers: {
        'x-fac-retry-attempt': '3',
        'x-fac-dedup-key': 'whatever',
        'x-fac-auth-token-fp': '10:99',
        'x-fac-retried-auth': '1',
        'if-none-match': 'W/"v1"',
      }));
      expect(withInternals, equals(bare),
          reason: 'internal/revalidation headers must not change identity');
    });

    test('a meaningful header (Accept) DOES change the key', () {
      final a =
          requestIdentityKey(_req(endpoint: '/r', headers: {'Accept': 'a'}));
      final b =
          requestIdentityKey(_req(endpoint: '/r', headers: {'Accept': 'b'}));
      expect(a, isNot(equals(b)));
    });

    test('stripInternalRequestHeaders removes exactly the internal set', () {
      final stripped = stripInternalRequestHeaders({
        'Authorization': 'Bearer x',
        'x-fac-retry-attempt': '2',
        'X-Fac-Dedup-Key': 'k', // case-insensitive
        'Accept': 'application/json',
      });
      expect(stripped.containsKey('x-fac-retry-attempt'), isFalse);
      expect(stripped.containsKey('X-Fac-Dedup-Key'), isFalse);
      expect(stripped['Authorization'], 'Bearer x',
          reason: 'Authorization is NOT internal — it goes on the wire');
      expect(stripped['Accept'], 'application/json');
    });
  });

  // ===========================================================================
  // INVARIANT D — retry backoff / Retry-After / jitter.
  //   (1) attempt count is monotone and bounded by maxAttempts (no infinite
  //       retry). (2) Retry-After is honoured but CLAMPED to maxDelay (a hostile
  //       server cannot wedge us). (3) full jitter stays within [0, capped].
  // ===========================================================================
  group('INV-D: retry policy bounds', () {
    test('retry stops at maxAttempts — total hits is bounded', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/always503$'), (_) async {
        hits++;
        return AdapterResponse(
            statusCode: 503, headers: const {}, bodyBytes: _b('busy'));
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          RetryInterceptor(
            policy: RetryPolicy(
              maxAttempts: 2, // explicit non-default bound
              baseDelay: const Duration(milliseconds: 1),
            ),
          ),
        ],
      ));
      final r = await within(client.get<dynamic>('always503'));
      expect(r.isSuccess, isFalse);
      // maxAttempts=2 => attempts 1,2 then stop. Exactly 2 network hits.
      expect(hits, 2, reason: 'bounded: maxAttempts network attempts, no more');
    });

    test('Retry-After is clamped to maxDelay (no server-induced wedge)', () {
      final policy = RetryPolicy(
        baseDelay: const Duration(milliseconds: 10),
        maxDelay: const Duration(milliseconds: 50),
      );
      final res = AdapterResponse(
        statusCode: 503,
        headers: const {'retry-after': '86400'}, // 24h
        bodyBytes: Uint8List(0),
      );
      final d = policy.delayFor(1, res);
      expect(d, const Duration(milliseconds: 50),
          reason: '24h Retry-After must be clamped to maxDelay');
    });

    test('negative / unparseable Retry-After falls back to backoff', () {
      final policy = RetryPolicy(
        useJitter: false,
        baseDelay: const Duration(milliseconds: 10),
      );
      final neg = policy.delayFor(
          1,
          AdapterResponse(
              statusCode: 503,
              headers: const {'retry-after': '-5'},
              bodyBytes: Uint8List(0)));
      // attempt 1 => 10ms * 2^0 = 10ms (backoff, not the bad header).
      expect(neg, const Duration(milliseconds: 10));
    });

    test('full jitter stays within [0, capped] for every attempt', () {
      final policy = RetryPolicy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 800),
      );
      for (var attempt = 1; attempt <= 6; attempt++) {
        final pow = 1 << (attempt - 1).clamp(0, 16);
        final capped = (const Duration(milliseconds: 100) * pow);
        final ceiling = capped > const Duration(milliseconds: 800)
            ? const Duration(milliseconds: 800)
            : capped;
        for (var i = 0; i < 200; i++) {
          final d = policy.delayFor(attempt, null);
          expect(d, greaterThanOrEqualTo(Duration.zero));
          expect(d, lessThanOrEqualTo(ceiling),
              reason: 'jitter never exceeds the capped ceiling');
        }
      }
    });

    test('unsafe methods are never retried (no double-write)', () {
      final policy = RetryPolicy(maxAttempts: 5);
      final res = AdapterResponse(
          statusCode: 503, headers: const {}, bodyBytes: Uint8List(0));
      expect(policy.shouldRetryResponse(res, 1, method: 'POST'), isFalse,
          reason: 'POST is not idempotent — must not auto-retry');
      expect(policy.shouldRetryResponse(res, 1, method: 'HEAD'), isTrue);
    });
  });

  // ===========================================================================
  // INVARIANT E — offline queue ordering, attempt counting, dead-lettering,
  //   and re-enqueue-failure survival.
  //   (1) replay processes in createdAt order. (2) every drained request is
  //   accounted for exactly once (succeeded+reEnqueued+deadLettered == total).
  //   (3) a transient failure increments attempts and is re-enqueued until it
  //   reaches maxAttempts, then dead-lettered (no infinite loop). (4) one
  //   enqueue failure mid-loop does not abandon the remaining requests.
  // ===========================================================================
  group('INV-E: offline queue replay', () {
    test('conservation: every drained request is accounted for exactly once',
        () async {
      final store = InMemoryOfflineQueueStore();
      // Three requests: one will succeed, one transient (re-enqueue), one
      // permanently rejected (dead-letter).
      await store.enqueue(QueuedRequest(
          id: 'ok',
          method: 'POST',
          endpoint: '/ok',
          headers: const {},
          createdAt: DateTime(2024)));
      await store.enqueue(QueuedRequest(
          id: 'transient',
          method: 'POST',
          endpoint: '/transient',
          headers: const {},
          createdAt: DateTime(2024, 1, 2)));
      await store.enqueue(QueuedRequest(
          id: 'reject',
          method: 'POST',
          endpoint: '/reject',
          headers: const {},
          createdAt: DateTime(2024, 1, 3)));

      final mock = MockAdapter();
      mock.on('POST', RegExp(r'/ok$'), statusCode: 200, body: {'ok': true});
      mock.onRequest('POST', RegExp(r'/transient$'),
          (_) async => throw const NetworkError('offline'));
      mock.on('POST', RegExp(r'/reject$'), statusCode: 400, body: {'no': true});

      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      final report = await within(
          OfflineQueueReplayer(store: store, client: client).replay());

      expect(report.total, 3);
      expect(report.succeeded, 1);
      expect(report.reEnqueued, 1);
      expect(report.deadLettered, 1);
      // Conservation law: no request vanished and none was double-counted.
      expect(report.succeeded + report.reEnqueued + report.deadLettered,
          report.total);
    });

    test('replay order is createdAt-ascending (FIFO by creation)', () async {
      final store = HiveMemoryStub();
      // Insert out of order; drain must sort.
      await store.enqueue(QueuedRequest(
          id: 'c',
          method: 'POST',
          endpoint: '/c',
          headers: const {},
          createdAt: DateTime(2024, 3)));
      await store.enqueue(QueuedRequest(
          id: 'a',
          method: 'POST',
          endpoint: '/a',
          headers: const {},
          createdAt: DateTime(2024)));
      await store.enqueue(QueuedRequest(
          id: 'b',
          method: 'POST',
          endpoint: '/b',
          headers: const {},
          createdAt: DateTime(2024, 2)));

      final order = <String>[];
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/[abc]$'), (req) async {
        order.add(req.url.path);
        return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('{}'));
      });
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      await within(OfflineQueueReplayer(store: store, client: client).replay());
      expect(order, ['/a', '/b', '/c'], reason: 'FIFO by createdAt');
    });

    test('poison message is dead-lettered after maxAttempts (no infinite loop)',
        () async {
      // A request that ALWAYS fails transiently must eventually stop. Start it
      // near the ceiling so a single replay pass dead-letters it.
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'poison',
          method: 'POST',
          endpoint: '/poison',
          headers: const {},
          createdAt: DateTime(2024),
          attempts: 1));
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/poison$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));

      // maxAttempts=2: attempts becomes 2 (>=2) => dead-lettered, NOT re-queued.
      final report = await within(
          OfflineQueueReplayer(store: store, client: client, maxAttempts: 2)
              .replay());
      expect(report.deadLettered, 1);
      expect(report.reEnqueued, 0);
      expect(await store.length, 0, reason: 'poison dropped, not looping');
    });

    test('attempt count increments across replay passes', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(QueuedRequest(
          id: 'r',
          method: 'POST',
          endpoint: '/r',
          headers: const {},
          createdAt: DateTime(2024)));
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/r$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      final replayer =
          OfflineQueueReplayer(store: store, client: client, maxAttempts: 5);

      await within(replayer.replay());
      final after1 = await store.drain();
      expect(after1.single.attempts, 1);
      // put it back for a second pass
      await store.enqueue(after1.single);
      await within(replayer.replay());
      final after2 = await store.drain();
      expect(after2.single.attempts, 2, reason: 'attempts are monotone');
    });

    test('re-enqueue failure mid-loop does not abandon remaining requests',
        () async {
      // The store's enqueue throws (disk full). The loop must survive: both
      // requests are processed, the failed re-enqueue is counted as a
      // dead-letter, nothing is silently dropped.
      final store = _ThrowOnEnqueueStore([
        QueuedRequest(
            id: '1',
            method: 'POST',
            endpoint: '/a',
            headers: const {},
            createdAt: DateTime(2024)),
        QueuedRequest(
            id: '2',
            method: 'POST',
            endpoint: '/b',
            headers: const {},
            createdAt: DateTime(2024, 1, 2)),
      ]);
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/[ab]$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      final report = await within(
          OfflineQueueReplayer(store: store, client: client).replay());
      expect(report.total, 2);
      expect(report.deadLettered, 2);
      expect(store.enqueueAttempts, 2,
          reason: 'both processed despite enqueue throwing');
    });

    test('queued mutation never persists an Authorization header', () async {
      // The replayer re-attaches a FRESH token; persisting the stale one would
      // be both a security leak and a correctness bug. Enqueue path must strip.
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(store: store, isOnline: () async => false),
        ],
      ));
      await client.post<dynamic>('save', {'n': 1},
          options: const RequestOptions(
              headers: {'Authorization': 'Bearer SECRET'}));
      final drained = await store.drain();
      expect(drained, hasLength(1));
      final hk =
          drained.single.headers.keys.map((k) => k.toLowerCase()).toList();
      expect(hk, isNot(contains('authorization')),
          reason: 'no stale secret persisted to disk');
    });

    test(
        'two same-instant same-endpoint enqueues get distinct ids (no clobber)',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(store: store, isOnline: () async => false),
        ],
      ));
      await client.post<dynamic>('save', {'n': 1});
      await client.post<dynamic>('save', {'n': 2});
      final drained = await store.drain();
      expect(drained.map((e) => e.id).toSet(), hasLength(2),
          reason: 'monotone seq guarantees id uniqueness — no keyed overwrite');
    });
  });
}

/// Offline store seeded with a fixed list whose [enqueue] always throws.
class _ThrowOnEnqueueStore implements OfflineQueueStore {
  _ThrowOnEnqueueStore(this._initial);
  final List<QueuedRequest> _initial;
  int enqueueAttempts = 0;

  @override
  Future<void> enqueue(QueuedRequest request) async {
    enqueueAttempts++;
    throw StateError('persist failed');
  }

  @override
  Future<List<QueuedRequest>> drain() async => List.of(_initial);
  @override
  Future<void> remove(String id) async {}
  @override
  Future<int> get length async => 0;
}

/// In-memory store that mimics [HiveOfflineQueueStore]'s sort-on-drain contract
/// (createdAt then id) WITHOUT a real Hive box, so the ordering invariant can be
/// proven hermetically.
class HiveMemoryStub implements OfflineQueueStore {
  final Map<String, QueuedRequest> _m = {};

  @override
  Future<void> enqueue(QueuedRequest request) async => _m[request.id] = request;

  @override
  Future<List<QueuedRequest>> drain() async {
    final out = _m.values.toList()
      ..sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    _m.clear();
    return out;
  }

  @override
  Future<void> remove(String id) async => _m.remove(id);
  @override
  Future<int> get length async => _m.length;
}
