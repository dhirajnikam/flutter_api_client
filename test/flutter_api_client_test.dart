import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiClient (basic instantiation)', () {
    test('with getAccessToken callback', () {
      final c = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://example.com',
          getAccessToken: () async => null,
        ),
      );
      expect(c, isNotNull);
    });

    test('with tokenStorage', () {
      final c = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://example.com',
          tokenStorage: MemoryTokenStorage(),
        ),
      );
      expect(c, isNotNull);
    });

    test('exposes verb methods', () {
      final c = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://example.com',
          getAccessToken: () async => null,
        ),
      );
      expect(c.get, isNotNull);
      expect(c.post, isNotNull);
      expect(c.put, isNotNull);
      expect(c.patch, isNotNull);
      expect(c.delete, isNotNull);
    });
  });

  group('ApiClient HTTP methods return ApiResult', () {
    late ApiClient client;

    setUp(() {
      final mock = MockAdapter();
      mock.on('GET', '/ping', statusCode: 200, body: {'ok': true});
      mock.on('GET', '/fail', statusCode: 404, body: {'message': 'not found'});
      client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://example.com',
        adapter: mock,
      ));
    });

    test('success result has data and isSuccess true', () async {
      final result = await client.get<Map<String, dynamic>>('/ping');
      expect(result.isSuccess, true);
      expect(result.data, {'ok': true});
      expect(result.errorMessage, isNull);
      expect(result.statusCode, 200);
    });

    test('failure result has errorMessage and isFailure true', () async {
      final result = await client.get<Map<String, dynamic>>('/fail');
      expect(result.isFailure, true);
      expect(result.data, isNull);
      expect(result.errorMessage, isNotNull);
      expect(result.statusCode, 404);
    });

    test('when() dispatches to correct branch', () async {
      final result = await client.get<Map<String, dynamic>>('/ping');
      final out = result.when(
        success: (d) => 'ok',
        failure: (e) => 'fail',
      );
      expect(out, 'ok');
    });
  });

  group('Token storage', () {
    test('memory get/set', () async {
      final s = MemoryTokenStorage(accessToken: 't');
      expect(await s.getAccessToken(), 't');
      await s.setAccessToken('x');
      expect(await s.getAccessToken(), 'x');
    });

    test('cached returns memory first', () async {
      final s = CachedTokenStorage(MemoryTokenStorage(accessToken: 'c'));
      expect(await s.getAccessToken(), 'c');
      s.updateAccessToken('new');
      expect(await s.getAccessToken(), 'new');
    });

    test('cached persists in background', () async {
      final inner = MemoryTokenStorage();
      final s = CachedTokenStorage(inner);
      s.updateAccessToken('immediate');
      expect(await s.getAccessToken(), 'immediate');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await inner.getAccessToken(), 'immediate');
    });
  });

  group('RequestOptions', () {
    test('defaults', () {
      const o = RequestOptions();
      expect(o.includeToken, true);
      expect(o.responseType, ResponseType.json);
      expect(o.maxRequestBodyBytes, isNull);
      expect(o.maxResponseBodyBytes, isNull);
    });

    test('copyWith', () {
      const o = RequestOptions();
      final n = o.copyWith(
        includeToken: false,
        maxRequestBodyBytes: 10,
        maxResponseBodyBytes: 20,
      );
      expect(n.includeToken, false);
      expect(n.maxRequestBodyBytes, 10);
      expect(n.maxResponseBodyBytes, 20);
    });
  });

  group('ApiClientConfig body limits', () {
    test('test config keeps body limits null by default', () {
      final config = ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: MockAdapter(),
      );
      expect(config.maxRequestBodyBytes, isNull);
      expect(config.maxResponseBodyBytes, isNull);
    });
  });

  group('CancelToken', () {
    test('cancels listeners', () {
      final t = CancelToken();
      var fired = 0;
      t.addListener((_) => fired++);
      t.cancel();
      expect(fired, 1);
      expect(t.isCancelled, true);
    });

    test('throwIfCancelled', () {
      final t = CancelToken();
      expect(() => t.throwIfCancelled(), returnsNormally);
      t.cancel();
      expect(() => t.throwIfCancelled(), throwsA(isA<CancelError>()));
    });
  });

  group('buildQueryString', () {
    test('simple', () {
      expect(buildQueryString({'a': 1, 'b': 'x'}), 'a=1&b=x');
    });
    test('list', () {
      expect(
        buildQueryString({
          'a': [1, 2],
        }),
        'a=1&a=2',
      );
    });
    test('nested', () {
      expect(
        buildQueryString({
          'filter': {'name': 'foo'},
        }),
        contains('filter%5Bname%5D=foo'),
      );
    });
    test('null skipped', () {
      expect(buildQueryString({'a': null, 'b': 1}), 'b=1');
    });
  });
}
