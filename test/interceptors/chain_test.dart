// InterceptorChain orchestration: hook ordering, short-circuits, restarts, the
// restart bound and the error funnel. Probe interceptors record into a shared
// trace so call order is asserted, not assumed.

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
    test('an interceptor that always proceeds is cut off', () async {
      final trace = <String>[];
      var transportHits = 0;
      // A retry that never stops must be cut off, not loop forever.
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

      expect(transportHits, inInclusiveRange(2, 100),
          reason: 'restarts happen, but only a bounded number of them');
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

  // A custom interceptor may proceed with a request it built by hand rather
  // than mutating or copying the one it was given. The built-in interceptors'
  // per-request state must survive that, or their bookkeeping silently resets.
  group('Interceptor state survives a rebuilt request', () {
    test('retry still stops at maxAttempts', () async {
      var calls = 0;
      final adapter = MockAdapter()
        ..onRequest('GET', '/flaky', (_) async {
          calls++;
          return AdapterResponse(
              statusCode: 503, headers: const {}, bodyBytes: Uint8List(0));
        });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: adapter,
        interceptors: [
          _Rebuilder(),
          RetryInterceptor(
              policy: RetryPolicy(maxAttempts: 2, baseDelay: Duration.zero)),
        ],
      ));

      final res = await client.get<dynamic>('/flaky');

      expect(calls, 2);
      expect(res.error, isA<HttpError>());
    });

    test('dedup releases its in-flight entry', () async {
      final adapter = MockAdapter()
        ..on('GET', '/a', statusCode: 200, body: {'ok': true});
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: adapter,
        interceptors: [
          DedupInterceptor(waitTimeout: const Duration(seconds: 5)),
          _Rebuilder(),
        ],
      ));

      await client.get<dynamic>('/a');
      // A leaked entry would make this wait out the whole waitTimeout.
      final second =
          await client.get<dynamic>('/a').timeout(const Duration(seconds: 1));

      expect(second.isSuccess, isTrue);
      expect(adapter.received, hasLength(2));
    });
  });
}

class _Rebuilder extends Interceptor {
  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async =>
      ProceedResult(InterceptedRequest(
        method: req.method,
        endpoint: req.endpoint,
        headers: {...req.headers},
        options: req.options,
        data: req.data,
        isMultipart: req.isMultipart,
      ));
}
