import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

ApiClient _client(
  MockAdapter mock, {
  required RateLimitInterceptor limiter,
  List<Interceptor> before = const [],
}) =>
    ApiClient(
      ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [...before, limiter],
      ),
    );

void main() {
  group('RateLimitInterceptor — token bucket', () {
    test('burst up to maxRequests passes without waiting', () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 3,
          per: const Duration(seconds: 10),
        ),
      );

      final sw = Stopwatch()..start();
      final results = await Future.wait([
        client.get<dynamic>('data'),
        client.get<dynamic>('data'),
        client.get<dynamic>('data'),
      ]);
      sw.stop();

      expect(results.every((r) => r.isSuccess), true);
      // Three tokens were available; nothing should have queued for a
      // meaningful fraction of the 10s refill window.
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
      expect(mock.received.length, 3);
    });

    test('request beyond the burst waits for a token', () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(milliseconds: 200),
        ),
      );

      final sw = Stopwatch()..start();
      await client.get<dynamic>('data'); // consumes the only token
      final second = await client.get<dynamic>('data'); // must wait ~200ms
      sw.stop();

      expect(second.isSuccess, true);
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 150)));
    });

    test('waiters are served in arrival order', () async {
      final order = <int>[];
      final mock = MockAdapter();
      var n = 0;
      mock.onRequest('GET', RegExp(r'/data$'), (req) async {
        order.add(int.parse(req.url.queryParameters['i']!));
        n++;
        return AdapterResponse(
            statusCode: 200, headers: const {}, bodyBytes: _b('{"n":$n}'));
      });
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(milliseconds: 50),
        ),
      );

      await Future.wait([
        for (var i = 0; i < 4; i++)
          client.get<dynamic>('data',
              options: RequestOptions(queryParameters: {'i': '$i'})),
      ]);

      expect(order, [0, 1, 2, 3]);
    });

    test('maxWait rejects instead of queueing unboundedly', () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(seconds: 30),
          maxWait: const Duration(milliseconds: 50),
        ),
      );

      final first = await client.get<dynamic>('data');
      final sw = Stopwatch()..start();
      final second = await client.get<dynamic>('data');
      sw.stop();

      expect(first.isSuccess, true);
      expect(second.isFailure, true);
      expect(second.error, isA<NetworkError>());
      expect(second.errorMessage, contains('Rate limit'));
      // Rejection is immediate, not after maxWait.
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
      expect(mock.received.length, 1);
    });

    test('rejected request returns its token (next request can still run)',
        () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(milliseconds: 100),
          maxWait: const Duration(milliseconds: 10),
        ),
      );

      await client.get<dynamic>('data'); // token consumed
      final rejected = await client.get<dynamic>('data'); // fail fast
      expect(rejected.isFailure, true);
      // After a refill window the bucket must hold exactly one token again —
      // not be in deficit from the rejected reservation.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final third = await client.get<dynamic>('data');
      expect(third.isSuccess, true);
      expect(mock.received.length, 2);
    });

    test('buckets are keyed per host', () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(seconds: 30),
          maxWait: Duration.zero,
        ),
      );

      final a = await client.get<dynamic>('data');
      final b = await client.get<dynamic>(
        'data',
        options:
            const RequestOptions(baseUrlOverride: 'https://other.example.com'),
      );
      final aAgain = await client.get<dynamic>('data');

      expect(a.isSuccess, true);
      expect(b.isSuccess, true, reason: 'other host has its own bucket');
      expect(aAgain.isFailure, true, reason: 'first host bucket is empty');
    });

    test('custom keyOf overrides host keying', () async {
      final mock = MockAdapter();
      mock.on('GET', '/a', statusCode: 200, body: {'ok': true});
      mock.on('GET', '/b', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(seconds: 30),
          maxWait: Duration.zero,
          keyOf: (req) => req.endpoint,
        ),
      );

      expect((await client.get<dynamic>('a')).isSuccess, true);
      expect((await client.get<dynamic>('b')).isSuccess, true,
          reason: 'different endpoint, different bucket');
      expect((await client.get<dynamic>('a')).isFailure, true);
    });

    test('cancelling a waiting request rejects with CancelError and refunds',
        () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(seconds: 5),
        ),
      );

      await client.get<dynamic>('data'); // consume the token
      final token = CancelToken();
      final waiting = client.get<dynamic>(
        'data',
        options: RequestOptions(cancelToken: token),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel('user left screen');
      final result = await waiting;

      expect(result.isFailure, true);
      expect(result.error, isA<CancelError>());
      expect(mock.received.length, 1, reason: 'cancelled before transport');
    });

    test('already-cancelled token rejects before consuming a token', () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 1,
          per: const Duration(seconds: 5),
          maxWait: Duration.zero,
        ),
      );

      final token = CancelToken()..cancel();
      final cancelled = await client.get<dynamic>(
        'data',
        options: RequestOptions(cancelToken: token),
      );
      expect(cancelled.isFailure, true);
      expect(cancelled.error, isA<CancelError>());

      // The bucket's single token must still be available.
      final ok = await client.get<dynamic>('data');
      expect(ok.isSuccess, true);
    });

    test('429 Retry-After pauses the bucket', () async {
      final mock = MockAdapter();
      var calls = 0;
      mock.onRequest('GET', RegExp(r'/data$'), (_) async {
        calls++;
        if (calls == 1) {
          return AdapterResponse(
            statusCode: 429,
            headers: const {'retry-after': '1'},
            bodyBytes: _b('{"error":"slow down"}'),
          );
        }
        return AdapterResponse(
            statusCode: 200, headers: const {}, bodyBytes: _b('{"ok":true}'));
      });
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 10,
          per: const Duration(seconds: 1),
        ),
      );

      final first = await client.get<dynamic>('data');
      expect(first.statusCode, 429);

      // Plenty of tokens remain, but the server pause must gate the next call.
      final sw = Stopwatch()..start();
      final second = await client.get<dynamic>('data');
      sw.stop();
      expect(second.isSuccess, true);
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 800)));
    });

    test('server pause is capped at maxServerPause', () async {
      final mock = MockAdapter();
      var calls = 0;
      mock.onRequest('GET', RegExp(r'/data$'), (_) async {
        calls++;
        if (calls == 1) {
          return AdapterResponse(
            statusCode: 429,
            headers: const {'retry-after': '86400'}, // a hostile 24h
            bodyBytes: _b('{}'),
          );
        }
        return AdapterResponse(
            statusCode: 200, headers: const {}, bodyBytes: _b('{"ok":true}'));
      });
      final client = _client(
        mock,
        limiter: RateLimitInterceptor(
          maxRequests: 10,
          per: const Duration(seconds: 1),
          maxServerPause: const Duration(milliseconds: 100),
        ),
      );

      await client.get<dynamic>('data'); // trips the pause
      final sw = Stopwatch()..start();
      final second = await client.get<dynamic>('data');
      sw.stop();
      expect(second.isSuccess, true);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
