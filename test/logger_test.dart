import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('CurlLogger', () {
    test('prints curl command for GET request', () async {
      final lines = <String>[];
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/users$'), statusCode: 200, body: []);

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [CurlLogger(printer: lines.add)],
        ),
      );

      await client.get<dynamic>('users');
      expect(lines, hasLength(1));
      expect(lines.first, startsWith('curl -X GET'));
      expect(lines.first, contains('users'));
    });

    test('redacts Authorization header', () async {
      final lines = <String>[];
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/secure$'), statusCode: 200, body: {});

      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'secret-token',
          interceptors: [CurlLogger(printer: lines.add)],
        ),
      );

      await client.get<dynamic>('secure');
      expect(lines.first, contains('<redacted>'));
      expect(lines.first, isNot(contains('secret-token')));
    });

    test('includes request body for POST', () async {
      final lines = <String>[];
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/echo$'), statusCode: 200, body: {});

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [CurlLogger(printer: lines.add)],
        ),
      );

      await client.post<dynamic>('echo', {'name': 'Alice'});
      expect(lines.first, contains('--data'));
      expect(lines.first, contains('Alice'));
    });

    test('redacts sensitive JSON body keys', () async {
      final lines = <String>[];
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/login$'), statusCode: 200, body: {});

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [CurlLogger(printer: lines.add)],
        ),
      );

      await client.post<dynamic>('login', {
        'email': 'a@b.com',
        'password': 'secret123',
        'accessToken': 'jwt-123',
      });

      expect(lines.first, contains('<redacted>'));
      expect(lines.first, isNot(contains('secret123')));
      expect(lines.first, isNot(contains('jwt-123')));
    });
  });

  group('PrettyLogger', () {
    test('logs request and response', () async {
      final lines = <String>[];
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/items$'), statusCode: 200, body: {'x': 1});

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [PrettyLogger(printer: lines.add, useColors: false)],
        ),
      );

      await client.get<dynamic>('items');
      expect(lines, hasLength(2)); // request + response
      expect(lines[0], contains('GET'));
      expect(lines[1], contains('200'));
    });

    test('redacts Authorization header in request log', () async {
      final lines = <String>[];
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/safe$'), statusCode: 200, body: {});

      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'my-secret',
          interceptors: [PrettyLogger(printer: lines.add, useColors: false)],
        ),
      );

      await client.get<dynamic>('safe');
      expect(lines[0], contains('<redacted>'));
      expect(lines[0], isNot(contains('my-secret')));
    });

    test('logs error when transport throws', () async {
      final lines = <String>[];
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/broken$'), (_) async {
        throw const NetworkError('down');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [PrettyLogger(printer: lines.add, useColors: false)],
        ),
      );

      await client.get<dynamic>('broken');
      expect(
          lines.any((l) => l.contains('broken') || l.contains('down')), true);
    });

    test('truncates long response body at 2000 chars with ellipsis', () async {
      final lines = <String>[];
      final longBody = 'x' * 3000;
      final mock = MockAdapter();
      mock.onRequest(
        'GET',
        RegExp(r'/big$'),
        (_) async => AdapterResponse(
          statusCode: 200,
          headers: const {},
          bodyBytes: _b(longBody),
        ),
      );

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [PrettyLogger(printer: lines.add, useColors: false)],
        ),
      );

      await client.get<dynamic>('big');
      final responseLine = lines.last;
      expect(responseLine, contains('…'));
    });

    test('redacts sensitive response headers and token-like response keys',
        () async {
      final lines = <String>[];
      final mock = MockAdapter();
      mock.onRequest(
        'GET',
        RegExp(r'/session$'),
        (_) async => AdapterResponse(
          statusCode: 200,
          headers: const {'set-cookie': 'sid=abc123; HttpOnly'},
          bodyBytes: _b('{"accessToken":"jwt-123","profile":{"name":"A"}}'),
        ),
      );

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [PrettyLogger(printer: lines.add, useColors: false)],
        ),
      );

      await client.get<dynamic>('session');

      final responseLog = lines.last;
      expect(responseLog, contains('set-cookie: <redacted>'));
      expect(responseLog, isNot(contains('sid=abc123')));
      expect(responseLog, contains('"accessToken":"<redacted>"'));
      expect(responseLog, isNot(contains('jwt-123')));
    });
  });
}
