import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiResult.when', () {
    test('calls success branch on Success', () {
      const result = Success<int>(42, statusCode: 200);
      final out = result.when(success: (d) => 'ok:$d', failure: (_) => 'fail');
      expect(out, 'ok:42');
    });

    test('calls failure branch on Failure', () {
      const result = Failure<int>(NetworkError('down'));
      final out =
          result.when(success: (_) => 'ok', failure: (e) => 'err:${e.message}');
      expect(out, 'err:down');
    });
  });

  group('ApiResult.map', () {
    test('transforms success value', () {
      const result = Success<int>(3, statusCode: 201);
      final mapped = result.map((d) => d * 2);
      expect(mapped, isA<Success<int>>());
      expect((mapped as Success<int>).data, 6);
      expect(mapped.statusCode, 201);
    });

    test('passes failure through unchanged', () {
      const err = TimeoutError('timed out');
      const result = Failure<int>(err);
      final mapped = result.map((d) => d * 2);
      expect(mapped, isA<Failure<int>>());
      expect((mapped as Failure<int>).error, err);
    });
  });

  group('ApiResult.dataOrNull / errorOrNull', () {
    test('dataOrNull returns data on success', () {
      const r = Success<String>('hello', statusCode: 200);
      expect(r.dataOrNull, 'hello');
      expect(r.errorOrNull, isNull);
    });

    test('dataOrNull returns null on failure', () {
      const r = Failure<String>(NetworkError('x'));
      expect(r.dataOrNull, isNull);
      expect(r.errorOrNull, isA<NetworkError>());
    });
  });

  group('ApiResult.isSuccess / isFailure', () {
    test('Success reports isSuccess true', () {
      expect(const Success<int>(1, statusCode: 200).isSuccess, true);
      expect(const Success<int>(1, statusCode: 200).isFailure, false);
    });

    test('Failure reports isFailure true', () {
      expect(const Failure<int>(NetworkError('x')).isFailure, true);
      expect(const Failure<int>(NetworkError('x')).isSuccess, false);
    });
  });

  group('ApiClient HTTP verb typed path', () {
    test('returns Success on 200', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/items$'), statusCode: 200, body: {'id': 7});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.get<Map<String, dynamic>>('items');
      expect(result.isSuccess, true);
      expect((result as Success<Map<String, dynamic>>).data, {'id': 7});
      expect(result.statusCode, 200);
    });

    test('returns Failure with HttpError on 404', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/gone$'),
            statusCode: 404, body: {'message': 'not found'});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.get<dynamic>('gone');
      expect(result.isFailure, true);
      final err = (result as Failure<dynamic>).error;
      expect(err, isA<HttpError>());
      expect((err as HttpError).statusCode, 404);
    });

    test('applies decoder to non-2xx JSON bodies', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/typed-error$'),
            statusCode: 422, body: {'message': 'invalid'});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.get<String>(
        'typed-error',
        decoder: (json) => (json as Map)['message'] as String,
      );

      expect(result.isFailure, true);
      final error = (result as Failure<String>).error as HttpError;
      expect(error.body, 'invalid');
      expect(result.statusCode, 422);
    });

    test('decoder is applied on Success', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/name$'), statusCode: 200, body: {'name': 'Bob'});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.get<String>(
        'name',
        decoder: (json) => (json as Map)['name'] as String,
      );
      expect(result.dataOrNull, 'Bob');
    });

    test('returns Failure with ParseError on malformed JSON success body', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/broken-json$'), (_) async => AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              bodyBytes: Uint8List.fromList(utf8.encode('{bad json')),
            ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://example.com', adapter: mock),
      );

      final result = await client.get<dynamic>('broken-json');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<ParseError>());
      expect(error.message, contains('Failed to parse JSON response'));

      expect(result.statusCode, 200);
    });

    test('returns Failure with ParseError on text body for JSON response', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/html$'), (_) async => AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'text/html'},
              bodyBytes: Uint8List.fromList(
                utf8.encode('<html><body>oops</body></html>'),
              ),
            ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://example.com', adapter: mock),
      );

      final result = await client.get<dynamic>('html');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<ParseError>());
      expect(error.message, contains('Expected JSON response body'));
    });

    test('accepts valid short JSON scalar success bodies', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/scalar$'), (_) async => AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              bodyBytes: Uint8List.fromList(utf8.encode('true')),
            ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://example.com', adapter: mock),
      );

      final result = await client.get<bool>('scalar');

      expect(result.isSuccess, true);
      expect(result.data, true);
    });

    test('returns Failure with ParseError on invalid utf8 success body', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/invalid-utf8-success$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {'content-type': 'application/json'},
                  bodyBytes: Uint8List.fromList([0x80]),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://example.com', adapter: mock),
      );

      final result = await client.get<dynamic>('invalid-utf8-success');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<ParseError>());
    });

    test('returns Success with null data on empty successful JSON body', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/no-content$'), (_) async => AdapterResponse(
              statusCode: 204,
              headers: const {},
              bodyBytes: Uint8List(0),
            ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://example.com', adapter: mock),
      );

      final result = await client.get<dynamic>('no-content');

      expect(result.isSuccess, true);
      expect(result.data, isNull);
      expect(result.statusCode, 204);
    });

    test('keeps non-2xx malformed payloads as HttpError', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/server-error$'), (_) async => AdapterResponse(
              statusCode: 500,
              headers: const {'content-type': 'application/json'},
              bodyBytes: Uint8List.fromList(utf8.encode('{bad json')),
            ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://example.com', adapter: mock),
      );

      final result = await client.get<dynamic>('server-error');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<HttpError>());
      expect((error as HttpError).statusCode, 500);
    });

    test('keeps non-2xx invalid utf8 payloads as HttpError', () async {
      final mock = MockAdapter()
        ..onRequest('GET', RegExp(r'/invalid-utf8-error$'),
            (_) async => AdapterResponse(
                  statusCode: 500,
                  headers: const {'content-type': 'application/json'},
                  bodyBytes: Uint8List.fromList([0x80]),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://example.com', adapter: mock),
      );

      final result = await client.get<dynamic>('invalid-utf8-error');

      expect(result.isFailure, true);
      final error = (result as Failure<dynamic>).error;
      expect(error, isA<HttpError>());
      expect((error as HttpError).statusCode, 500);
    });
  });

  group('ApiResult convenience getters', () {
    test('data returns value on Success', () {
      const r = Success<int>(42, statusCode: 200, headers: {'x-id': '1'});
      expect(r.data, 42);
      expect(r.error, isNull);
      expect(r.errorMessage, isNull);
      expect(r.statusCode, 200);
      expect(r.headers, {'x-id': '1'});
    });

    test('data returns null on Failure', () {
      const r = Failure<int>(HttpError('not found', statusCode: 404));
      expect(r.data, isNull);
      expect(r.error, isA<HttpError>());
      expect(r.errorMessage, 'not found');
      expect(r.statusCode, 404);
      expect(r.headers, <String, String>{});
    });

    test('Failure with no statusCode returns null statusCode', () {
      const r = Failure<int>(NetworkError('offline'));
      expect(r.statusCode, isNull);
      expect(r.errorMessage, 'offline');
    });
  });

  group('ApiException subtypes', () {
    test('NetworkError toString contains message', () {
      const e = NetworkError('socket closed');
      expect(e.toString(), contains('socket closed'));
      expect(e, isA<ApiException>());
    });

    test('TimeoutError carries message', () {
      const e = TimeoutError('30s exceeded');
      expect(e.message, '30s exceeded');
    });

    test('ParseError carries message', () {
      const e = ParseError('bad json');
      expect(e.message, 'bad json');
    });

    test('HttpError carries statusCode and body', () {
      const e = HttpError('forbidden', statusCode: 403, body: {'msg': 'no'});
      expect(e.statusCode, 403);
      expect(e.body, {'msg': 'no'});
    });

    test('UnknownError carries cause', () {
      final cause = Exception('raw');
      final e = UnknownError('wrap', cause: cause);
      expect(e.cause, cause);
    });

    test('CancelError has default message', () {
      const e = CancelError();
      expect(e.message, 'Request cancelled');
    });
  });
}
