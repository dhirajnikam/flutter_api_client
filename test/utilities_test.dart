import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('FormData.fromMap', () {
    test('converts plain values to fields', () {
      final fd = FormData.fromMap({'name': 'Alice', 'age': 30});
      expect(fd.fields['name'], 'Alice');
      expect(fd.fields['age'], '30');
      expect(fd.files, isEmpty);
    });

    test('ignores null values', () {
      final fd = FormData.fromMap({'a': null, 'b': 'val'});
      expect(fd.fields.containsKey('a'), false);
      expect(fd.fields['b'], 'val');
    });

    test('collects MultipartFile into files list', () {
      final file = http.MultipartFile.fromString('upload', 'content');
      final fd = FormData.fromMap({'file': file});
      expect(fd.files, hasLength(1));
      expect(fd.files.first, same(file));
    });

    test('collects List<MultipartFile> into files list', () {
      final f1 = http.MultipartFile.fromString('a', 'x');
      final f2 = http.MultipartFile.fromString('b', 'y');
      final fd = FormData.fromMap({'attachments': [f1, f2]});
      expect(fd.files, hasLength(2));
    });

    test('repeats list values as bracketed fields', () {
      final fd = FormData.fromMap({'tags': ['dart', 'flutter']});
      expect(fd.fields.containsKey('tags[]'), true);
    });

    test('isEmpty and isNotEmpty reflect content', () {
      expect(FormData.fromMap({}).isEmpty, true);
      expect(FormData.fromMap({'k': 'v'}).isNotEmpty, true);
    });
  });

  group('CancelToken listener removal', () {
    test('unregistered listener is not called on cancel', () {
      final token = CancelToken();
      var fired = 0;
      final remove = token.addListener((_) => fired++);
      remove(); // unregister before cancel
      token.cancel();
      expect(fired, 0);
    });

    test('listener added after cancel fires immediately', () {
      final token = CancelToken();
      token.cancel('done');
      var fired = 0;
      token.addListener((_) => fired++);
      expect(fired, 1);
    });

    test('second cancel is a no-op', () {
      final token = CancelToken();
      var fired = 0;
      token.addListener((_) => fired++);
      token.cancel();
      token.cancel(); // second call ignored
      expect(fired, 1);
    });
  });

  group('buildUri edge cases', () {
    test('merges query when endpoint already has ?', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'search?q=foo',
        queryParameters: {'page': '2'},
      );
      expect(uri.toString(), contains('q=foo'));
      expect(uri.toString(), contains('page=2'));
      expect(uri.toString(), contains('&'));
    });

    test('base URL without trailing slash and endpoint without leading slash', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'users',
      );
      expect(uri.toString(), 'https://api.example.com/users');
    });

    test('base URL with trailing slash normalised', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com/',
        endpoint: '/users',
      );
      expect(uri.toString(), 'https://api.example.com/users');
    });

    test('empty queryParameters produces no query string', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'ping',
        queryParameters: {},
      );
      expect(uri.toString(), 'https://api.example.com/ping');
    });
  });

  group('CachedTokenStorage.clearCache', () {
    test('after clearCache next read hits delegate again', () async {
      var delegateReads = 0;
      final inner = _CountingStorage(onRead: () {
        delegateReads++;
        return 'token-from-delegate';
      });
      final cached = CachedTokenStorage(inner);

      await cached.getAccessToken();
      expect(delegateReads, 1);

      await cached.getAccessToken(); // uses cache
      expect(delegateReads, 1);

      cached.clearCache();

      await cached.getAccessToken(); // must hit delegate again
      expect(delegateReads, 2);
    });

    test('clear() awaits delegate.clear() and drops cache', () async {
      final inner = MemoryTokenStorage(accessToken: 'abc');
      final cached = CachedTokenStorage(inner);

      await cached.getAccessToken(); // warms cache

      await cached.clear();

      expect(await cached.getAccessToken(), isNull);
      expect(await inner.getAccessToken(), isNull);
    });
  });

  group('AuthInterceptor edge cases', () {
    test('skips auth header when includeToken is false', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/pub$'), statusCode: 200, body: {});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'should-not-appear',
        ),
      );

      await client.get<dynamic>(
        'pub',
        options: const RequestOptions(includeToken: false),
      );

      expect(mock.received.first.headers.containsKey('Authorization'), false);
    });

    test('skips auth header when token is empty string', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/open$'), statusCode: 200, body: {});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => '',
        ),
      );

      await client.get<dynamic>('open');
      expect(mock.received.first.headers.containsKey('Authorization'), false);
    });

    test('uses custom authScheme prefix', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/api$'), statusCode: 200, body: {});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'mytoken',
          authScheme: 'Token',
        ),
      );

      await client.get<dynamic>('api');
      expect(mock.received.first.headers['Authorization'], 'Token mytoken');
    });

    test('empty authScheme sends bare token without prefix', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/raw$'), statusCode: 200, body: {});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'rawtoken',
          authScheme: '',
        ),
      );

      await client.get<dynamic>('raw');
      expect(mock.received.first.headers['Authorization'], 'rawtoken');
    });
  });
}

/// Test double that counts delegate reads.
class _CountingStorage implements TokenStorage {
  _CountingStorage({required String Function() onRead}) : _onRead = onRead;

  final String Function() _onRead;

  @override
  Future<String?> getAccessToken() async => _onRead();

  @override
  Future<void> setAccessToken(String? token) async {}

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<void> setRefreshToken(String? token) async {}

  @override
  Future<void> clear() async {}
}
