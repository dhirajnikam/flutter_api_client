import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

AdapterResponse _ok() => AdapterResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      bodyBytes: _b('{}'),
    );

void main() {
  group('RetryInterceptor.onError path', () {
    test('retries on NetworkError then succeeds', () async {
      var attempts = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (req) async {
        attempts++;
        if (attempts < 3) {
          throw const NetworkError('connection reset');
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List.fromList('{"ok":true}'.codeUnits),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 4,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );

      final res = await client.get<dynamic>('flaky');
      expect(res.isSuccess, true);
      expect(attempts, 3);
    });

    test('retries on TimeoutError then succeeds', () async {
      var attempts = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/slow$'), (req) async {
        attempts++;
        if (attempts < 2) throw const TimeoutError('took too long');
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: Uint8List.fromList('{"done":true}'.codeUnits),
        );
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );

      final res = await client.get<dynamic>('slow');
      expect(res.isSuccess, true);
      expect(attempts, 2);
    });

    test('gives up after maxAttempts on persistent NetworkError', () async {
      var attempts = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/dead$'), (req) async {
        attempts++;
        throw const NetworkError('always down');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 2,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );

      final res = await client.get<dynamic>('dead');
      expect(res.isSuccess, false);
      expect(res.errorMessage, contains('always down'));
      expect(attempts, 2);
    });

    test('does not retry on HttpError (non-retryable exception)', () async {
      var attempts = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/auth$'), (req) async {
        attempts++;
        throw const HttpError('forbidden', statusCode: 403);
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );

      final res = await client.get<dynamic>('auth');
      expect(res.isSuccess, false);
      expect(attempts, 1);
    });
  });

  // ===========================================================================
  // Retry backoff / Retry-After / jitter.
  //   (1) attempt count is monotone and bounded by maxAttempts (no infinite
  //       retry). (2) Retry-After is honoured but CLAMPED to maxDelay (a hostile
  //       server cannot wedge us). (3) full jitter stays within [0, capped].
  // ===========================================================================
  group('retry policy bounds', () {
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
      final garbage = policy.delayFor(
          1,
          AdapterResponse(
              statusCode: 503,
              headers: const {'retry-after': 'soon'},
              bodyBytes: Uint8List(0)));
      expect(garbage, const Duration(milliseconds: 10));
    });

    test('full jitter stays within [0, capped] for every attempt', () {
      final policy = RetryPolicy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 800),
      );
      // base * 2^(attempt-1), capped at maxDelay.
      const ceilingsMs = [100, 200, 400, 800, 800, 800];
      for (var attempt = 1; attempt <= ceilingsMs.length; attempt++) {
        final ceiling = Duration(milliseconds: ceilingsMs[attempt - 1]);
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

  group('RetryPolicy — header casing', () {
    test('capitalised Retry-After is honoured over exponential backoff',
        () async {
      var calls = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        calls++;
        if (calls == 1) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {'Retry-After': '0'},
            bodyBytes: Uint8List(0),
          );
        }
        return _ok();
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          RetryInterceptor(
            policy: RetryPolicy(
              baseDelay: const Duration(seconds: 20),
              useJitter: false,
            ),
          ),
        ],
      ));

      final sw = Stopwatch()..start();
      final result = await client.get<dynamic>('flaky');
      sw.stop();

      expect(result.isSuccess, true);
      expect(calls, 2);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'Retry-After: 0 must beat the 20s exponential backoff');
    });
  });

  group('Retry backoff', () {
    test('custom backoff replaces the exponential formula', () {
      final policy = RetryPolicy(
        useJitter: false,
        backoff: (attempt) => Duration(seconds: attempt * 10),
      );
      expect(policy.delayFor(1, null), const Duration(seconds: 10));
      expect(policy.delayFor(2, null), const Duration(seconds: 20));
    });

    test('custom backoff is still capped at maxDelay', () {
      final policy = RetryPolicy(
        useJitter: false,
        maxDelay: const Duration(seconds: 5),
        backoff: (attempt) => const Duration(seconds: 60),
      );
      expect(policy.delayFor(3, null), const Duration(seconds: 5));
    });

    test('default backoff unchanged (exponential from baseDelay)', () {
      final policy = RetryPolicy(useJitter: false);
      expect(policy.delayFor(1, null), const Duration(milliseconds: 200));
      expect(policy.delayFor(2, null), const Duration(milliseconds: 400));
      expect(policy.delayFor(3, null), const Duration(milliseconds: 800));
    });
  });

  group('RetryPolicy.delayFor — Retry-After', () {
    AdapterResponse resWithRetryAfter(String value) => AdapterResponse(
          statusCode: 503,
          headers: {'retry-after': value},
          bodyBytes: Uint8List(0),
        );

    test('honours a small delta-seconds value verbatim', () {
      final policy = RetryPolicy(maxDelay: const Duration(seconds: 10));
      expect(
        policy.delayFor(1, resWithRetryAfter('5')),
        const Duration(seconds: 5),
      );
    });

    test('parses an HTTP-date and clamps a far-future date to maxDelay', () {
      final policy = RetryPolicy(maxDelay: const Duration(seconds: 10));
      expect(
        policy.delayFor(1, resWithRetryAfter('Wed, 21 Oct 2099 07:28:00 GMT')),
        const Duration(seconds: 10),
      );
    });
  });

  group('RetryInterceptor', () {
    test('retries on 503 then succeeds', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        hits++;
        if (hits < 3) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: _b('busy'),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"ok":true}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 4,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );
      final res = await client.get<dynamic>('flaky');
      expect(res.isSuccess, true);
      expect(hits, 3);
      for (final request in mock.received) {
        expect(
          request.headers.keys
              .where((key) => key.toLowerCase().startsWith('x-fac-')),
          isEmpty,
        );
      }
    });

    test('does not retry non-safe methods on 503 by default', () async {
      var hits = 0;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/submit$'), (_) async {
        hits++;
        if (hits == 1) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: _b('busy'),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b('{"ok":true}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 4,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );
      final res = await client.post<dynamic>('submit', {'id': 1});
      expect(res.isSuccess, false);
      expect(res.statusCode, 503);
      expect(hits, 1);
    });

    test('gives up after maxAttempts', () async {
      final mock = MockAdapter();
      mock.onRequest(
        'GET',
        RegExp(r'/dead$'),
        (_) async => AdapterResponse(
          statusCode: 503,
          headers: const {},
          bodyBytes: _b('busy'),
        ),
      );
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            RetryInterceptor(
              policy: RetryPolicy(
                maxAttempts: 2,
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );
      final res = await client.get<dynamic>('dead');
      expect(res.isSuccess, false);
      expect(res.statusCode, 503);
      expect(mock.received, hasLength(2));
    });
  });
}
