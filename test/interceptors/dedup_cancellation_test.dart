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

void main() {
  group('DedupInterceptor — cancellation isolation', () {
    test('a cancelled leader does not fail innocent followers', () async {
      final chain = InterceptorChain([DedupInterceptor()]);
      var calls = 0;
      final leaderGate = Completer<void>();
      Future<AdapterResponse> transport(InterceptedRequest req) async {
        calls++;
        if (calls == 1) {
          await leaderGate.future;
          throw const CancelError();
        }
        return _ok();
      }

      final leaderOutcome = chain
          .run(request: _req('/feed'), transport: transport)
          .then<Object>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(Duration.zero);
      final followerFuture =
          chain.run(request: _req('/feed'), transport: transport);
      await Future<void>.delayed(Duration.zero);
      leaderGate.complete();

      expect(await leaderOutcome, isA<CancelError>());
      final follower = await followerFuture;
      expect(follower.statusCode, 200,
          reason: "the follower's own token was never cancelled, so it must "
              'fall back to its own request');
      expect(calls, 2);
    });

    test('a follower whose own token fires stops waiting promptly', () async {
      final chain = InterceptorChain([DedupInterceptor()]);
      final leaderGate = Completer<AdapterResponse>();
      Future<AdapterResponse> transport(InterceptedRequest req) =>
          leaderGate.future;

      final leaderFuture =
          chain.run(request: _req('/slow'), transport: transport);
      await Future<void>.delayed(Duration.zero);

      final token = CancelToken();
      final sw = Stopwatch()..start();
      final followerFuture = chain.run(
        request: _req('/slow', token: token),
        transport: transport,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel('user left the screen');

      await expectLater(followerFuture, throwsA(isA<CancelError>()));
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the follower must not block on the leader or waitTimeout');

      leaderGate.complete(_ok());
      final leader = await leaderFuture;
      expect(leader.statusCode, 200, reason: 'the leader is undisturbed');
    });
  });
}
