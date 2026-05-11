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
      final out = result.when(success: (_) => 'ok', failure: (e) => 'err:${e.message}');
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

  group('ApiClient.request() typed path', () {
    test('returns Success on 200', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/items$'), statusCode: 200, body: {'id': 7});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.request<Map<String, dynamic>>('GET', 'items');
      expect(result.isSuccess, true);
      expect((result as Success<Map<String, dynamic>>).data, {'id': 7});
      expect(result.statusCode, 200);
    });

    test('returns Failure with HttpError on 404', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/gone$'), statusCode: 404, body: {'message': 'not found'});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.request<dynamic>('GET', 'gone');
      expect(result.isFailure, true);
      final err = (result as Failure<dynamic>).error;
      expect(err, isA<HttpError>());
      expect((err as HttpError).statusCode, 404);
    });

    test('decoder is applied on Success', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/name$'), statusCode: 200, body: {'name': 'Bob'});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.request<String>(
        'GET',
        'name',
        decoder: (json) => (json as Map)['name'] as String,
      );
      expect(result.dataOrNull, 'Bob');
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
