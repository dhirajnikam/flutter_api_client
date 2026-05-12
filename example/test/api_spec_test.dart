// GENERATED CODE - DO NOT MODIFY BY HAND
// Regenerate: dart run flutter_api_client:gen --only tests

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/my_spec.dart';

void main() {
  group('Users', () {
    test('GET /users — happy path', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://dummyjson.com',
          adapter: SpecMockAdapter(mySpec),
        ),
      );
      final res = await client.get<dynamic>('users');
      expect(res.isSuccess, true);
    });

    test('GET /users — auth required returns 401', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://dummyjson.com',
          adapter: SpecMockAdapter(
            mySpec,
            statusOverrides: const {'GET /users': 401},
          ),
        ),
      );
      final res = await client.get<dynamic>('users');
      expect(res.statusCode, 401);
    });

    test('GET /users/{id} — happy path', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://dummyjson.com',
          adapter: SpecMockAdapter(mySpec),
        ),
      );
      final res = await client.get<dynamic>('users/1');
      expect(res.isSuccess, true);
    });

    test('GET /users/{id} — auth required returns 401', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://dummyjson.com',
          adapter: SpecMockAdapter(
            mySpec,
            statusOverrides: const {'GET /users/{id}': 401},
          ),
        ),
      );
      final res = await client.get<dynamic>('users/1');
      expect(res.statusCode, 401);
    });
  });
}
