import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_api_client/flutter_api_client.dart';

void main() {
  group('ApiClient', () {
    test('can be instantiated with config (getAccessToken)', () {
      final config = ApiClientConfig(
        baseUrl: 'https://api.example.com/api/v1',
        getAccessToken: () async => null,
      );
      final apiClient = ApiClient(config);
      expect(apiClient, isNotNull);
    });

    test('can be instantiated with config (tokenStorage)', () {
      final config = ApiClientConfig(
        baseUrl: 'https://api.example.com/api/v1',
        tokenStorage: MemoryTokenStorage(),
      );
      final apiClient = ApiClient(config);
      expect(apiClient, isNotNull);
    });

    test('can be instantiated with ApiClientConfig.withToken', () {
      final config = ApiClientConfig.withToken(
        baseUrl: 'https://api.example.com/api/v1',
        getAccessToken: () async => null,
      );
      final apiClient = ApiClient(config);
      expect(apiClient, isNotNull);
    });

    test('can be instantiated with ApiClientConfig.withStorage', () {
      final config = ApiClientConfig.withStorage(
        baseUrl: 'https://api.example.com/api/v1',
        tokenStorage: MemoryTokenStorage(),
      );
      final apiClient = ApiClient(config);
      expect(apiClient, isNotNull);
    });

    test('exposes get, post, put, patch, delete methods', () {
      final config = ApiClientConfig(
        baseUrl: 'https://api.example.com/api/v1',
        getAccessToken: () async => null,
      );
      final apiClient = ApiClient(config);
      expect(apiClient.get, isNotNull);
      expect(apiClient.post, isNotNull);
      expect(apiClient.put, isNotNull);
      expect(apiClient.patch, isNotNull);
      expect(apiClient.delete, isNotNull);
    });

    test('get returns Future with RequestOptions', () {
      final config = ApiClientConfig(
        baseUrl: 'https://api.example.com/api/v1',
        getAccessToken: () async => null,
      );
      final apiClient = ApiClient(config);
      final future = apiClient.get(
        'users',
        options: const RequestOptions(includeToken: false),
      );
      expect(future, isA<Future<CustomApiResponse>>());
    });
  });

  group('CustomApiResponse', () {
    test('creates success response correctly', () {
      final response = CustomApiResponse(
        statusCode: 200,
        headers: {},
        data: {'id': 1},
        isSuccess: true,
      );
      expect(response.isSuccess, isTrue);
      expect(response.statusCode, 200);
      expect(response.data, {'id': 1});
      expect(response.errorMessage, isNull);
    });

    test('creates error response correctly', () {
      final response = CustomApiResponse(
        statusCode: 400,
        headers: {},
        data: null,
        isSuccess: false,
        errorMessage: 'Bad request',
      );
      expect(response.isSuccess, isFalse);
      expect(response.errorMessage, 'Bad request');
    });
  });

  group('TokenStorage', () {
    test('MemoryTokenStorage stores and retrieves token', () async {
      final storage = MemoryTokenStorage(accessToken: 'test-token');
      expect(await storage.getAccessToken(), 'test-token');
      await storage.setAccessToken('new-token');
      expect(await storage.getAccessToken(), 'new-token');
      await storage.setAccessToken(null);
      expect(await storage.getAccessToken(), isNull);
    });
  });

  group('RequestOptions', () {
    test('creates with defaults', () {
      const options = RequestOptions();
      expect(options.includeToken, isTrue);
      expect(options.headers, isNull);
      expect(options.timeout, isNull);
      expect(options.baseUrlOverride, isNull);
    });

    test('copyWith works', () {
      const options = RequestOptions();
      final updated = options.copyWith(includeToken: false);
      expect(updated.includeToken, isFalse);
    });
  });
}
