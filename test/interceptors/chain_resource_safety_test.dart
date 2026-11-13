import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

InterceptedRequest _req(String endpoint, {CancelToken? token}) =>
    InterceptedRequest(
      method: 'GET',
      endpoint: endpoint,
      headers: {},
      options: RequestOptions(cancelToken: token),
    );

AdapterResponse _ok() => AdapterResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      bodyBytes: _b('{}'),
    );

/// Restarts the chain once on a 503, mimicking a retry decision.
class _RetryOnceOn503 extends Interceptor {
  bool _retried = false;

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    if (res.statusCode == 503 && !_retried) {
      _retried = true;
      return ProceedResult(req.copy());
    }
    return ResolveResult(res);
  }
}

/// Pathological interceptor that restarts the chain on every response,
/// guaranteeing the retry-depth limit is hit.
class _AlwaysProceed extends Interceptor {
  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async =>
      ProceedResult(req.copy());
}

void main() {
  group('InterceptorChain — resource safety', () {
    test('a streamed response discarded by a chain restart is drained',
        () async {
      var listened = false;
      var calls = 0;
      Future<AdapterResponse> transport(InterceptedRequest req) async {
        calls++;
        if (calls == 1) {
          final controller = StreamController<List<int>>(
            onListen: () => listened = true,
          );
          controller
            ..add([1, 2, 3])
            ..close();
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: Uint8List(0),
            bodyStream: controller.stream,
          );
        }
        return _ok();
      }

      final chain = InterceptorChain([_RetryOnceOn503()]);
      final res = await chain.run(request: _req('/big'), transport: transport);

      expect(res.statusCode, 200);
      expect(listened, isTrue,
          reason: 'the discarded streamed body must be drained so the '
              'adapter can release its client');
    });

    test('depth-exceeded still lets interceptors clean up (dedup released)',
        () async {
      final dedup = DedupInterceptor();
      final chain = InterceptorChain([dedup, _AlwaysProceed()]);
      Future<AdapterResponse> transport(InterceptedRequest req) async => _ok();

      await expectLater(
        chain.run(request: _req('/loop'), transport: transport),
        throwsA(isA<UnknownError>()),
      );

      // A dead leader left in dedup's in-flight map would stall this second
      // identical request for the full 30s waitTimeout.
      final sw = Stopwatch()..start();
      await expectLater(
        chain.run(request: _req('/loop'), transport: transport),
        throwsA(isA<UnknownError>()),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the dedup entry from the first run must have been released');
    });
  });
}
