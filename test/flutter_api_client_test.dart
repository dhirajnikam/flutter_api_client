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

  group('CustomApiResponse', () {
    test('success', () {
      final r = CustomApiResponse<Map<String, dynamic>>(
        statusCode: 200,
        headers: const {},
        data: const {'id': 1},
        isSuccess: true,
      );
      expect(r.isSuccess, true);
      expect(r.data, {'id': 1});
    });
    test('error', () {
      final r = CustomApiResponse<dynamic>(
        statusCode: 400,
        headers: const {},
        data: null,
        isSuccess: false,
        errorMessage: 'bad',
      );
      expect(r.isSuccess, false);
      expect(r.errorMessage, 'bad');
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
    });
    test('copyWith', () {
      const o = RequestOptions();
      final n = o.copyWith(includeToken: false);
      expect(n.includeToken, false);
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
