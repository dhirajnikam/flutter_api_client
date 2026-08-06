import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('MetricsInterceptor', () {
    test('emits one metric per successful request', () async {
      final metrics = <ApiRequestMetric>[];
      final mock = MockAdapter();
      mock.on('GET', '/users', statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [MetricsInterceptor(onMetric: metrics.add)],
        ),
      );

      final result = await client.get<dynamic>('users');
      expect(result.isSuccess, true);
      expect(metrics, hasLength(1));
      final m = metrics.single;
      expect(m.method, 'GET');
      expect(m.endpoint, 'users');
      expect(m.statusCode, 200);
      expect(m.error, isNull);
      expect(m.completed, true);
      expect(m.attempts, 1);
      expect(m.fromCache, false);
      expect(m.duration, greaterThanOrEqualTo(Duration.zero));
    });

    test('metric carries the final error on failure', () async {
      final metrics = <ApiRequestMetric>[];
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/down$'), (_) async {
        throw const NetworkError('unreachable');
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [MetricsInterceptor(onMetric: metrics.add)],
        ),
      );

      final result = await client.get<dynamic>('down');
      expect(result.isFailure, true);
      expect(metrics, hasLength(1));
      expect(metrics.single.error, isA<NetworkError>());
      expect(metrics.single.completed, false);
      expect(metrics.single.statusCode, isNull);
    });

    test('a non-2xx response is one completed metric, not an error', () async {
      final metrics = <ApiRequestMetric>[];
      final mock = MockAdapter();
      mock.on('GET', '/missing', statusCode: 404, body: {'error': 'nope'});
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [MetricsInterceptor(onMetric: metrics.add)],
        ),
      );

      await client.get<dynamic>('missing');
      expect(metrics, hasLength(1));
      expect(metrics.single.statusCode, 404);
      expect(metrics.single.error, isNull);
    });

    test('retried request emits ONE metric with total attempts and duration',
        () async {
      final metrics = <ApiRequestMetric>[];
      final mock = MockAdapter();
      var calls = 0;
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        calls++;
        if (calls < 3) {
          return AdapterResponse(
              statusCode: 503, headers: const {}, bodyBytes: _b('{}'));
        }
        return AdapterResponse(
            statusCode: 200, headers: const {}, bodyBytes: _b('{"ok":true}'));
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            // Metrics FIRST so it wraps the retry loop.
            MetricsInterceptor(onMetric: metrics.add),
            RetryInterceptor(
              policy: RetryPolicy(
                baseDelay: const Duration(milliseconds: 1),
                useJitter: false,
              ),
            ),
          ],
        ),
      );

      final result = await client.get<dynamic>('flaky');
      expect(result.isSuccess, true);
      expect(calls, 3);
      expect(metrics, hasLength(1));
      expect(metrics.single.attempts, 3);
      expect(metrics.single.statusCode, 200);
    });

    test('cache hits are flagged fromCache', () async {
      final metrics = <ApiRequestMetric>[];
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'n': 1});
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            MetricsInterceptor(onMetric: metrics.add),
            CacheInterceptor(
              store: MemoryCacheStore(),
              defaultPolicy: CachePolicy.cacheFirst(ttl: const Duration(minutes: 1)),
            ),
          ],
        ),
      );

      await client.get<dynamic>('data'); // network, fills cache
      await client.get<dynamic>('data'); // served from cache
      expect(metrics, hasLength(2));
      expect(metrics[0].fromCache, false);
      expect(metrics[1].fromCache, true);
      expect(mock.received, hasLength(1));
    });

    test('tag is echoed onto the metric', () async {
      final metrics = <ApiRequestMetric>[];
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [MetricsInterceptor(onMetric: metrics.add)],
        ),
      );

      await client.get<dynamic>(
        'data',
        options: const RequestOptions(tag: 'home-screen'),
      );
      expect(metrics.single.tag, 'home-screen');
    });

    test('a throwing listener does not affect the request', () async {
      final mock = MockAdapter();
      mock.on('GET', '/data', statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            MetricsInterceptor(onMetric: (_) => throw StateError('boom')),
          ],
        ),
      );

      final result = await client.get<dynamic>('data');
      expect(result.isSuccess, true);
    });

    test('concurrent requests are tracked independently', () async {
      final metrics = <ApiRequestMetric>[];
      final mock = MockAdapter();
      mock.on('GET', '/a', statusCode: 200, body: {'ok': true});
      mock.on('GET', '/b',
          statusCode: 200,
          body: {'ok': true},
          delay: const Duration(milliseconds: 50));
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [MetricsInterceptor(onMetric: metrics.add)],
        ),
      );

      await Future.wait([
        client.get<dynamic>('a'),
        client.get<dynamic>('b'),
      ]);
      expect(metrics, hasLength(2));
      final byEndpoint = {for (final m in metrics) m.endpoint: m};
      expect(byEndpoint.keys, containsAll(['a', 'b']));
      expect(byEndpoint['a']!.attempts, 1);
      expect(byEndpoint['b']!.attempts, 1);
    });
  });
}
