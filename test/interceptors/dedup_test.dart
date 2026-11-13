import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart' hide within;

import '../support/liveness.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

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

class _AddHeaderInterceptor extends Interceptor {
  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    req.headers['X-Stamp'] = '1';
    return ProceedResult(req);
  }
}

void main() {
  // ===========================================================================
  // Dedup coalescing.
  //   At most one network request per identity key is in flight. Followers
  //   either (a) share the leader's buffered response, or (b) fall back to
  //   their own request, but NEVER hang past waitTimeout and NEVER deadlock the
  //   leader. The owner of the key (re-entry on retry) always proceeds.
  // ===========================================================================
  group('dedup leader/follower coalescing', () {
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
      // The candidate deadlock: a retry restarts the chain, so the leader
      // re-enters dedup while its own entry is still in flight. If dedup did
      // not recognise the owner, the leader would wait on itself forever.
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
      // A leader that errors (or streams) with ZERO followers must not leave
      // an unobserved error future behind: Dart reports that as an unhandled
      // asynchronous error in the surrounding zone, which crashes apps.
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

  group('DedupInterceptor — streaming follower not left hanging', () {
    test('follower shares a buffered leader response', () async {
      final dedup = DedupInterceptor();
      final leader = _req(endpoint: '/b');
      final lr = await dedup.onRequest(leader);
      final leaderProceed = (lr as ProceedResult).request;

      final follower = _req(endpoint: '/b');
      final followerFuture = dedup.onRequest(follower);

      final res = AdapterResponse(
        statusCode: 200,
        headers: const {},
        bodyBytes: _b('shared'),
      );
      await dedup.onResponse(leaderProceed, res);

      final fr = await followerFuture;
      expect(fr, isA<ResolveResult>());
      expect(utf8.decode((fr as ResolveResult).response.bodyBytes), 'shared');
    });
  });

  group('DedupInterceptor — retry re-entry', () {
    test('a retried deduped GET does not deadlock', () async {
      var calls = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/retry$'), (req) async {
        calls++;
        if (calls == 1) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List.fromList(utf8.encode('{"ok":true}')),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            DedupInterceptor(),
            RetryInterceptor(
              policy: RetryPolicy(
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
                retryOnStatus: const {503},
              ),
            ),
          ],
        ),
      );

      final res = await client
          .get<dynamic>('retry')
          .timeout(const Duration(seconds: 5));
      expect(res.isSuccess, true);
      expect(calls, 2);
    });

    // The retried copy carries the header a later interceptor added, so its
    // identity key differs from the one the entry was registered under. The
    // entry must still be released, or the next identical GET waits on it.
    test('a header added downstream does not leak the in-flight entry',
        () async {
      var calls = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/stamped$'), (req) async {
        calls++;
        return AdapterResponse(
          statusCode: calls == 1 ? 503 : 200,
          headers: const {},
          bodyBytes: _b('{"ok":true}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            DedupInterceptor(waitTimeout: const Duration(seconds: 5)),
            RetryInterceptor(
              policy: RetryPolicy(
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
            _AddHeaderInterceptor(),
          ],
        ),
      );

      final first = await client.get<dynamic>('stamped');
      expect(first.isSuccess, true);
      expect(calls, 2);

      final second = await client
          .get<dynamic>('stamped')
          .timeout(const Duration(seconds: 1));
      expect(second.isSuccess, true);
      expect(calls, 3);
    });
  });

  group('DedupInterceptor', () {
    test('does not coalesce requests with different authorization headers',
        () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"auth":"${req.headers['Authorization']}"}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [DedupInterceptor()],
        ),
      );
      final results = await Future.wait([
        client.get<dynamic>(
          'me',
          options: const RequestOptions(
            headers: {'Authorization': 'Bearer user-a'},
          ),
        ),
        client.get<dynamic>(
          'me',
          options: const RequestOptions(
            headers: {'Authorization': 'Bearer user-b'},
          ),
        ),
      ]);

      expect(hits, 2);
      expect(results[0].dataOrNull, {'auth': 'Bearer user-a'});
      expect(results[1].dataOrNull, {'auth': 'Bearer user-b'});
    });
  });

  test('a request retried from above dedup is coalesced again', () async {
    var calls = 0;
    final mock = MockAdapter();
    mock.onRequest('GET', RegExp(r'/p$'), (req) async {
      final n = ++calls;
      if (n == 1) {
        return AdapterResponse(
            statusCode: 503, headers: const {}, bodyBytes: Uint8List(0));
      }
      await Future<void>.delayed(Duration(milliseconds: n == 2 ? 60 : 200));
      return AdapterResponse(
        statusCode: 200,
        headers: const {},
        bodyBytes: Uint8List.fromList(utf8.encode('{"call":$n}')),
      );
    });
    final client = ApiClient(ApiClientConfig.test(
      baseUrl: 'https://api.example.com',
      adapter: mock,
      interceptors: [
        RetryInterceptor(
          policy: RetryPolicy(
            baseDelay: const Duration(milliseconds: 1),
            useJitter: false,
            retryOnStatus: const {503},
          ),
        ),
        DedupInterceptor(),
      ],
    ));

    // `first` gets a 503 and retries; the others arrive while that retry is
    // in flight, so they must all share its response.
    final first = client.get<dynamic>('p');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final others = [client.get<dynamic>('p'), client.get<dynamic>('p')];
    final results = await Future.wait([first, ...others]);

    expect(calls, 2);
    expect(results.map((r) => r.data), everyElement({'call': 2}));
  });
}
