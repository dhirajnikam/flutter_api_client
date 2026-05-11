import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

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
                maxAttempts: 3,
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
                maxAttempts: 3,
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
}
