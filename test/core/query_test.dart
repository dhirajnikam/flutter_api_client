import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // =========================================================================
  // QUERY STRING + URI EDGE CASES. The places a naive builder emits a
  // malformed URL.
  // =========================================================================
  group('query + URI edge cases', () {
    test('null values are dropped, not encoded as "null"', () {
      expect(buildQueryString({'a': 1, 'b': null, 'c': 'x'}), 'a=1&c=x');
    });

    test('a map whose every value is null yields an empty query', () {
      expect(buildQueryString({'a': null, 'b': null}), '');
    });

    test('list values repeat the key', () {
      expect(
          buildQueryString({
            'id': [1, 2, 3]
          }),
          'id=1&id=2&id=3');
    });

    test('nested maps bracket the key', () {
      expect(
          buildQueryString({
            'filter': {'name': 'foo'}
          }),
          'filter%5Bname%5D=foo');
    });

    test('special characters in keys and values are percent-encoded', () {
      // Uri.encodeQueryComponent encodes a space as '+' (application/x-www-form-
      // urlencoded form-component semantics) and reserved chars (& =) as %xx.
      final q = buildQueryString({'a b': 'c&d=e', 'q': 'hello world'});
      expect(q, contains('a+b=c%26d%3De'));
      expect(q, contains('q=hello+world'));
    });

    test('buildUri normalises slashes and appends ? for a fresh query', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com/',
        endpoint: '/v1/items',
        queryParameters: {'page': 2},
      );
      expect(uri.toString(), 'https://api.example.com/v1/items?page=2');
    });

    test('buildUri uses & when the endpoint already carries a query', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items?sort=asc',
        queryParameters: {'page': 2},
      );
      expect(uri.toString(), 'https://api.example.com/items?sort=asc&page=2');
    });

    test('buildUri handles an endpoint ending in a bare ? (no double &)', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items?',
        queryParameters: {'page': 2},
      );
      expect(uri.toString(), 'https://api.example.com/items?page=2');
    });

    test('empty query parameters never append a stray ?', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items',
        queryParameters: const {},
      );
      expect(uri.toString(), 'https://api.example.com/items');
    });

    test('a list value of nulls collapses to nothing', () {
      expect(
          buildQueryString({
            'id': [null, null]
          }),
          '');
    });
  });

  group('buildUri query merge', () {
    test('endpoint without query starts with ?', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items',
        queryParameters: {'a': '1'},
      );
      expect(uri.toString(), 'https://api.example.com/items?a=1');
    });
  });

  group('Query encoding', () {
    test('default buildQueryString unchanged (repeated keys, dropped nulls)',
        () {
      final qs = buildQueryString({
        'tags': ['a', 'b'],
        'q': null,
        'filter': {'name': 'foo'},
      });
      expect(qs, 'tags=a&tags=b&filter%5Bname%5D=foo');
    });

    test('comma list format', () {
      final qs = buildQueryString(
        {
          'tags': ['a', 'b', 'c']
        },
        const QueryEncoder(listFormat: QueryListFormat.comma),
      );
      expect(qs, 'tags=a,b,c');
    });

    test('bracket list format + dotted nesting + includeNulls', () {
      final qs = buildQueryString(
        {
          'tags': ['a', 'b'],
          'q': null,
          'filter': {'name': 'foo'},
        },
        const QueryEncoder(
          listFormat: QueryListFormat.brackets,
          nested: QueryNestedStyle.dotted,
          includeNulls: true,
        ),
      );
      expect(qs, 'tags%5B%5D=a&tags%5B%5D=b&q=&filter.name=foo');
    });

    test('client threads its queryEncoder through to the URL', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          queryEncoder: const QueryEncoder(listFormat: QueryListFormat.comma),
        ),
      );
      await client.get<dynamic>('x',
          options: const RequestOptions(queryParameters: {
            'ids': [1, 2, 3]
          }));
      expect(mock.received.single.url.query, 'ids=1,2,3');
    });
  });

  group('buildQueryString', () {
    test('simple', () {
      expect(buildQueryString({'a': 1, 'b': 'x'}), 'a=1&b=x');
    });
  });

  group('buildUri edge cases', () {
    test('base URL without trailing slash and endpoint without leading slash',
        () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'users',
      );
      expect(uri.toString(), 'https://api.example.com/users');
    });
  });
}
