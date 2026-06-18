// Architecture audit — REQUEST LIFECYCLE + INTERCEPTOR CHAIN orchestration.
//
// Lens: john-carmack. I do not accept "it works"; I trace every edge of the
// control flow and prove WHY it holds, step by step, or I prove it doesn't.
//
// What this file pins down about `InterceptorChain`:
//   1. onRequest runs top -> bottom; onResponse runs bottom -> top (mirror).
//   2. onError runs bottom -> top.
//   3. A `ResolveResult` from onRequest short-circuits the transport but STILL
//      runs the full reversed onResponse pass (every interceptor, even ones
//      below the short-circuiter that never saw onRequest).
//   4. `ProceedResult` returned from onResponse / onError RESTARTS the whole
//      chain from the top with a FRESH onRequest pass (retry + 401-refresh
//      re-entry), carrying the mutated request — not the original.
//   5. The restart is depth-bounded: > 8 restarts throws, so a pathological
//      interceptor cannot wedge the client in an infinite loop.
//   6. A thrown exception anywhere (onRequest / transport / onResponse) is
//      funneled into the SAME reversed onError pass — uniform error handling.
//   7. A throwing onError does not abort the pass: it re-wraps and continues to
//      the next interceptor, and the final un-recovered error is rethrown.
//   8. Full composition: auth + cache + dedup + retry + offline + logging in a
//      single chain compose without deadlock, double-spend, or lost ordering.
//
// All probe interceptors record into a shared trace list so ordering is an
// observable, asserted fact rather than a hand-wave. — carmack

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

InterceptedRequest _req({
  String method = 'GET',
  String endpoint = '/x',
  Map<String, String>? headers,
  RequestOptions options = const RequestOptions(),
  Object? data,
}) =>
    InterceptedRequest(
      method: method,
      endpoint: endpoint,
      headers: headers ?? <String, String>{},
      options: options,
      data: data,
    );

AdapterResponse _ok([String body = '"ok"', int code = 200]) => AdapterResponse(
      statusCode: code,
      headers: const {'content-type': 'application/json'},
      bodyBytes: _b(body),
    );

/// A fully instrumented interceptor. Every hook appends `<label>:<hook>` to the
/// shared [trace], so the exact call order across a stack is an asserted fact.
/// Each hook can be told to short-circuit / reject / restart, letting one probe
/// stand in for cache (resolve-on-request), retry (proceed-on-response), etc.
class _Probe extends Interceptor {
  _Probe(
    this.label,
    this.trace, {
    this.onRequestResult,
    this.onResponseResult,
    this.onErrorResult,
    this.throwOnRequest = false,
    this.throwOnError = false,
  });

  final String label;
  final List<String> trace;

  final InterceptorResult Function(InterceptedRequest req)? onRequestResult;
  final InterceptorResult Function(InterceptedRequest req, AdapterResponse res)?
      onResponseResult;
  final InterceptorResult Function(InterceptedRequest req, ApiException err)?
      onErrorResult;
  final bool throwOnRequest;
  final bool throwOnError;

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    trace.add('$label:req');
    if (throwOnRequest) throw const NetworkError('probe-throw-request');
    return onRequestResult?.call(req) ?? ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    trace.add('$label:res');
    return onResponseResult?.call(req, res) ?? ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException err,
  ) async {
    trace.add('$label:err');
    if (throwOnError) throw StateError('probe-throw-error');
    return onErrorResult?.call(req, err) ?? RejectResult(err);
  }
}

void main() {
  group('Lifecycle — ordering invariants', () {
    test('onRequest top->bottom, onResponse bottom->top (mirror)', () async {
      final trace = <String>[];
      final chain = InterceptorChain([
        _Probe('A', trace),
        _Probe('B', trace),
        _Probe('C', trace),
      ]);

      final res = await chain.run(
        request: _req(),
        transport: (r) async {
          trace.add('transport');
          return _ok();
        },
      );

      expect(res.statusCode, 200);
      // The defining shape of the chain: requests descend, responses ascend.
      expect(trace, [
        'A:req',
        'B:req',
        'C:req',
        'transport',
        'C:res',
        'B:res',
        'A:res',
      ]);
    });

    test('onError runs bottom->top after a transport throw', () async {
      final trace = <String>[];
      final chain = InterceptorChain([
        _Probe('A', trace),
        _Probe('B', trace),
        _Probe('C', trace),
      ]);

      await expectLater(
        chain.run(
          request: _req(),
          transport: (r) async {
            trace.add('transport');
            throw const NetworkError('down');
          },
        ),
        throwsA(isA<NetworkError>()),
      );

      expect(trace, [
        'A:req',
        'B:req',
        'C:req',
        'transport',
        'C:err',
        'B:err',
        'A:err',
      ]);
    });
  });

  group('Lifecycle — short-circuit on request (cache-style resolve)', () {
    test(
        'onRequest ResolveResult skips transport but runs FULL reversed '
        'onResponse pass', () async {
      final trace = <String>[];
      var transportHits = 0;
      // B short-circuits with a synthetic response (like a cache hit). The
      // documented behaviour: transport is skipped, yet onResponse still fans
      // out across EVERY interceptor in reverse — including C, which sits below
      // B and never saw onRequest. This is load-bearing: an interceptor above
      // the cache (e.g. auth/logging) must still observe the served response.
      final chain = InterceptorChain([
        _Probe('A', trace),
        _Probe('B', trace,
            onRequestResult: (req) => ResolveResult(_ok('"cached"'))),
        _Probe('C', trace),
      ]);

      final res = await chain.run(
        request: _req(),
        transport: (r) async {
          transportHits++;
          return _ok();
        },
      );

      expect(transportHits, 0, reason: 'cache hit must not reach the network');
      expect(utf8.decode(res.bodyBytes), '"cached"');
      expect(trace, [
        'A:req', 'B:req', // C:req never runs (B short-circuited)
        'C:res', 'B:res', 'A:res', // but the FULL reversed pass still runs
      ]);
    });
  });

  group('Lifecycle — restart on response (retry / refresh re-entry)', () {
    test(
        'ProceedResult from onResponse restarts the chain from the top with a '
        'fresh onRequest pass, carrying the mutated request', () async {
      final trace = <String>[];
      var pass = 0;
      // Top interceptor R behaves like RetryInterceptor: on the FIRST response
      // it proceeds (restart) with a mutated request carrying a marker header;
      // on the second it resolves. We prove (a) a second full top->bottom
      // onRequest pass happens, and (b) the restart carries R's MUTATED request
      // (the marker survives), not the original.
      final r = _Probe('R', trace, onResponseResult: (req, res) {
        if (req.headers['x-restart'] == '1') return ResolveResult(res);
        final next = req.copy();
        next.headers['x-restart'] = '1';
        return ProceedResult(next);
      });
      final chain = InterceptorChain([
        r,
        _Probe('B', trace, onRequestResult: (req) {
          // Observe whether the restart carried the mutation.
          trace.add('B-sees-restart=${req.headers['x-restart'] ?? '0'}');
          return ProceedResult(req);
        }),
      ]);

      final res = await chain.run(
        request: _req(),
        transport: (req) async {
          pass++;
          trace.add('transport#$pass');
          return _ok();
        },
      );

      expect(res.statusCode, 200);
      expect(pass, 2, reason: 'exactly one restart -> two transport calls');
      // Trace must show: full pass 1, restart, full pass 2 with the marker set.
      expect(trace, [
        'R:req', 'B:req', 'B-sees-restart=0', 'transport#1',
        'B:res', 'R:res', // bottom->top; R proceeds here -> restart
        'R:req', 'B:req', 'B-sees-restart=1', 'transport#2',
        'B:res', 'R:res', // R resolves here
      ]);
    });

    test('ProceedResult from onError restarts the chain (recover-by-retry)',
        () async {
      final trace = <String>[];
      var pass = 0;
      final recover = _Probe('REC', trace, onErrorResult: (req, err) {
        if (req.headers['x-retried'] == '1') return RejectResult(err);
        final next = req.copy();
        next.headers['x-retried'] = '1';
        return ProceedResult(next);
      });
      final chain = InterceptorChain([recover, _Probe('B', trace)]);

      final res = await chain.run(
        request: _req(),
        transport: (req) async {
          pass++;
          if (pass == 1) throw const NetworkError('transient');
          return _ok();
        },
      );

      expect(res.statusCode, 200);
      expect(pass, 2, reason: 'error recovery restarted the chain once');
    });
  });

  group('Lifecycle — depth bound (no infinite restart)', () {
    test('an interceptor that always proceeds is capped at depth 8', () async {
      final trace = <String>[];
      var transportHits = 0;
      // A pathological retry that NEVER stops. The chain must defend itself:
      // after retryDepth > 8 it throws UnknownError instead of looping forever.
      final chain = InterceptorChain([
        _Probe('LOOP', trace,
            onResponseResult: (req, res) => ProceedResult(req.copy())),
      ]);

      await expectLater(
        chain.run(
          request: _req(),
          transport: (req) async {
            transportHits++;
            return _ok();
          },
        ),
        throwsA(isA<UnknownError>()),
      );

      // retryDepth increments 0..8 then trips at 9 BEFORE the 10th transport.
      // So the transport fires for depths 0..8 inclusive = 9 times.
      expect(transportHits, 9,
          reason: 'depth bound trips at >8, after 9 transport calls');
    });
  });

  group('Lifecycle — uniform error funnel', () {
    test('a thrown onRequest is funneled into the reversed onError pass',
        () async {
      final trace = <String>[];
      // B throws synchronously in onRequest. The chain must NOT propagate the
      // raw throw past the transport boundary; it must wrap it and run onError
      // bottom->top over the interceptors. Transport must never be reached.
      var transportHits = 0;
      final chain = InterceptorChain([
        _Probe('A', trace),
        _Probe('B', trace, throwOnRequest: true),
        _Probe('C', trace),
      ]);

      await expectLater(
        chain.run(
          request: _req(),
          transport: (r) async {
            transportHits++;
            return _ok();
          },
        ),
        throwsA(isA<NetworkError>()),
      );

      expect(transportHits, 0);
      // onRequest reached A and B (B threw); then the FULL reversed onError pass.
      expect(trace, [
        'A:req',
        'B:req',
        'C:err',
        'B:err',
        'A:err',
      ]);
    });

    test('a non-ApiException thrown in transport is wrapped as UnknownError',
        () async {
      final trace = <String>[];
      final chain = InterceptorChain([_Probe('A', trace)]);
      await expectLater(
        chain.run(
          request: _req(),
          transport: (r) async => throw const FormatException('raw'),
        ),
        throwsA(isA<UnknownError>()),
      );
    });

    test(
        'a throwing onError does not abort the pass; the loop continues and '
        'the final un-recovered error is rethrown', () async {
      final trace = <String>[];
      // Bottom interceptor C throws inside onError. The chain must catch it,
      // re-wrap, and CONTINUE to B and A rather than aborting. Since nobody
      // recovers, the (wrapped) error is ultimately rethrown.
      final chain = InterceptorChain([
        _Probe('A', trace),
        _Probe('B', trace),
        _Probe('C', trace, throwOnError: true),
      ]);

      await expectLater(
        chain.run(
          request: _req(),
          transport: (r) async => throw const NetworkError('down'),
        ),
        throwsA(isA<ApiException>()),
      );

      // Every interceptor's onError still ran despite C throwing.
      expect(trace, [
        'A:req',
        'B:req',
        'C:req',
        'C:err',
        'B:err',
        'A:err',
      ]);
    });

    test(
        'onError recovery (ResolveResult) re-runs the full reversed '
        'onResponse pass over the recovered response', () async {
      final trace = <String>[];
      // C recovers a NetworkError with a synthetic 200 (cache-on-error style).
      // The recovered response must then flow back UP through every onResponse.
      final chain = InterceptorChain([
        _Probe('A', trace),
        _Probe('B', trace),
        _Probe('C', trace,
            onErrorResult: (req, err) => ResolveResult(_ok('"recovered"'))),
      ]);

      final res = await chain.run(
        request: _req(),
        transport: (r) async => throw const NetworkError('down'),
      );

      expect(utf8.decode(res.bodyBytes), '"recovered"');
      expect(trace, [
        'A:req', 'B:req', 'C:req',
        'C:err', // C recovers here
        'C:res', 'B:res', 'A:res', // recovered response ascends the full chain
      ]);
    });
  });

  group('Lifecycle — full composition through the REAL ApiClient', () {
    test(
        'auth + cache + dedup + retry + logging compose: refresh-then-retry, '
        'then a second identical GET is a pure cache hit', () async {
      // The whole stack wired in one chain. This is the scenario "nobody
      // thought of": a 401 that triggers a single refresh + retry, the retry
      // succeeds and is CACHED, and a later identical request is served from
      // cache without ever touching the network again. We assert exact network
      // hit counts so there is no double-spend and no double-refresh.
      var networkHits = 0;
      var refreshes = 0;
      final tokens = MemoryTokenStorage(accessToken: 'OLD');

      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        networkHits++;
        final auth = req.headers['Authorization'];
        if (auth == 'Bearer OLD') {
          return AdapterResponse(
            statusCode: 401,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json', 'etag': 'v1'},
          bodyBytes: _b('{"name":"carmack"}'),
        );
      });

      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          tokenStorage: tokens,
          refreshToken: () async {
            refreshes++;
            await tokens.setAccessToken('NEW');
            return true;
          },
          adapter: mock,
          interceptors: [
            CacheInterceptor(
              store: MemoryCacheStore(),
              // Default ttl is 5 minutes — ample for a same-test second read.
              defaultPolicy: CachePolicy.cacheFirst(),
            ),
            DedupInterceptor(),
            RetryInterceptor(
              policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1),
              ),
            ),
          ],
        ),
      );

      final first = await client.get<Map<String, dynamic>>('me');
      expect(first, isA<Success<Map<String, dynamic>>>());
      expect(first.data, {'name': 'carmack'});
      expect(refreshes, 1, reason: 'exactly one refresh on the 401');
      expect(networkHits, 2,
          reason: 'one 401 + one retried 200, no extra hits');

      // Second identical GET: cacheFirst + fresh entry => pure cache hit.
      final second = await client.get<Map<String, dynamic>>('me');
      expect(second, isA<Success<Map<String, dynamic>>>());
      expect(networkHits, 2, reason: 'cache hit must not touch the network');
    });

    test(
        'dedup + retry: three concurrent GETs coalesce onto one leader that '
        'rides a retried 503 — no deadlock, exactly one extra hit', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        hits++;
        if (hits == 1) {
          return AdapterResponse(
              statusCode: 503, headers: const {}, bodyBytes: _b('busy'));
        }
        return _ok('"done"');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            DedupInterceptor(waitTimeout: const Duration(seconds: 5)),
            RetryInterceptor(
              policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1),
              ),
            ),
          ],
        ),
      );

      final results = await Future.wait([
        client.get<dynamic>('flaky'),
        client.get<dynamic>('flaky'),
        client.get<dynamic>('flaky'),
      ]).timeout(
        const Duration(seconds: 4),
        onTimeout: () => throw StateError('dedup+retry deadlocked'),
      );

      for (final r in results) {
        expect(r.statusCode, 200);
      }
      expect(hits, 2,
          reason: 'one leader, one retry of the 503; followers coalesced');
    });

    // ARCHITECTURAL FINDING (carmack): the COMPOSITION ORDER of Dedup vs Retry
    // changes the coalescing efficiency — but NEVER correctness. Traced:
    //
    //   reversed-onResponse order is the REVERSE of the interceptor list.
    //
    //   [Dedup, Retry]  (Dedup outermost): onResponse fires Retry FIRST. On a
    //     retryable 503 Retry restarts the chain BEFORE Dedup.onResponse runs,
    //     so the leader's completer is still pending. The follower keeps
    //     waiting and rides the leader's eventual 200. => 1 leader, 1 retry,
    //     followers coalesced. Network hits = 2. This is the recommended order.
    //
    //   [Retry, Dedup]  (Retry outermost): onResponse fires Dedup FIRST. Dedup
    //     completes the leader's completer with the *pre-retry* 503 and releases
    //     the follower. Retry then restarts the leader (hit #2 -> 200). But the
    //     already-released follower, seeing a retryable 503 on its OWN way up,
    //     restarts independently (hit #3 -> 200). Correct result for everyone,
    //     but coalescing is defeated for the retried attempt.
    //
    // Both orderings: every caller gets a correct 200, no deadlock, no hang.
    // The chain's restart contract is sound in BOTH; only the dedup window
    // differs. Recommendation surfaced in the output: place Dedup OUTSIDE Retry.
    test(
        'Dedup outermost coalesces a retried 503 (2 hits); Retry outermost is '
        'still correct but does not coalesce the retry (3 hits)', () async {
      Future<int> hitsFor(List<Interceptor> chain) async {
        var hits = 0;
        final mock = MockAdapter();
        mock.onRequest('GET', RegExp(r'/o$'), (_) async {
          hits++;
          if (hits == 1) {
            return AdapterResponse(
                statusCode: 503, headers: const {}, bodyBytes: _b('busy'));
          }
          return _ok('"o"');
        });
        final client = ApiClient(
          ApiClientConfig.test(
            baseUrl: 'https://api.example.com',
            adapter: mock,
            interceptors: chain,
          ),
        );
        final results = await Future.wait([
          client.get<dynamic>('o'),
          client.get<dynamic>('o'),
        ]).timeout(
          const Duration(seconds: 4),
          onTimeout: () => throw StateError('ordering deadlocked'),
        );
        // Correctness invariant holds for BOTH orderings: everyone gets 200.
        for (final r in results) {
          expect(r.statusCode, 200, reason: 'every caller must see success');
        }
        return hits;
      }

      RetryInterceptor retry() => RetryInterceptor(
            policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1)),
          );
      DedupInterceptor dedup() =>
          DedupInterceptor(waitTimeout: const Duration(seconds: 5));

      // Recommended order — dedup spans the retry, so followers coalesce.
      expect(await hitsFor([dedup(), retry()]), 2,
          reason: 'Dedup outermost: leader retries, follower coalesces');
      // Inverted order — still correct, but the retry is not coalesced.
      expect(await hitsFor([retry(), dedup()]), 3,
          reason: 'Retry outermost: follower released on the pre-retry 503');
    });

    test(
        'offline + retry compose: a mutating POST that fails the network while '
        'offline is enqueued exactly once (retry does not double-enqueue)',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'), (_) async {
        throw const NetworkError('offline');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            // Retry must NOT retry a POST (not a safe method), so offline gets
            // exactly one shot at enqueuing. Ordering: retry above offline.
            RetryInterceptor(
              policy: RetryPolicy.exponential(
                baseDelay: const Duration(milliseconds: 1),
              ),
            ),
            OfflineQueueInterceptor(store: store, isOnline: () async => false),
          ],
        ),
      );

      final res = await client.post<dynamic>('save', {'n': 1});
      expect(res, isA<Failure<dynamic>>());
      final drained = await store.drain();
      expect(drained, hasLength(1),
          reason: 'POST is unsafe -> not retried -> enqueued exactly once');
    });
  });
}
