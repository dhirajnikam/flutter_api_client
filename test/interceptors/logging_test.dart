import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

InterceptedRequest _req({
  String method = 'GET',
  String endpoint = '/x',
  Map<String, String>? headers,
  Object? data,
}) =>
    InterceptedRequest(
      method: method,
      endpoint: endpoint,
      headers: headers ?? <String, String>{},
      options: const RequestOptions(),
      data: data,
    );

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
      expect(lines, hasLength(2));
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
      expect(lines.last, allOf(contains('broken'), contains('down')),
          reason: 'the failure itself is logged, not just the request');
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
      expect(responseLine, contains('${'x' * 2000}…'));
      expect(responseLine, isNot(contains('x' * 2001)));
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

  group('Logger — case-insensitive header redaction', () {
    test('PrettyLogger redacts a mixed-case caller-supplied header', () async {
      final lines = <String>[];
      final logger = PrettyLogger(
        printer: lines.add,
        useColors: false,
        redactHeaders: const {'Authorization', 'X-Secret'}, // mixed case
      );
      await logger.onRequest(_req(
        headers: {'Authorization': 'Bearer abc', 'X-Secret': 'hush'},
      ));
      final out = lines.join('\n');
      expect(out, contains('<redacted>'));
      expect(out, isNot(contains('Bearer abc')));
      expect(out, isNot(contains('hush')));
    });

    test('CurlLogger redacts a mixed-case caller-supplied header', () async {
      final lines = <String>[];
      final logger = CurlLogger(
        printer: lines.add,
        redactHeaders: const {'Authorization'},
      );
      await logger.onRequest(_req(
        headers: {'Authorization': 'Bearer abc'},
      ));
      expect(lines.single, isNot(contains('Bearer abc')));
      expect(lines.single, contains('<redacted>'));
    });
  });

  group('credential and long-body redaction', () {
    Future<List<String>> logged(Interceptor logger) async {
      final mock = MockAdapter()
        ..on('GET', '/me', statusCode: 200, body: {
          'password': 'hunter2',
          'padding': 'x' * 3000,
        });
      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        tokenStorage: MemoryTokenStorage(accessToken: 'secret-token'),
        authHeaderName: 'X-Session',
        interceptors: [logger],
      ));
      await client.get<dynamic>('me');
      return [];
    }

    test('PrettyLogger hides a custom-named auth header', () async {
      final lines = <String>[];
      await logged(PrettyLogger(printer: lines.add, useColors: false));
      expect(lines.join('\n'), contains('X-Session: <redacted>'));
      expect(lines.join('\n'), isNot(contains('secret-token')));
    });

    test('CurlLogger hides a custom-named auth header', () async {
      final lines = <String>[];
      await logged(CurlLogger(printer: lines.add));
      expect(lines.join('\n'), isNot(contains('secret-token')));
    });

    test('PrettyLogger redacts a body that is longer than the preview',
        () async {
      final lines = <String>[];
      await logged(PrettyLogger(printer: lines.add, useColors: false));
      expect(lines.join('\n'), isNot(contains('hunter2')));
      expect(lines.join('\n'), contains('…'));
    });
  });
}
