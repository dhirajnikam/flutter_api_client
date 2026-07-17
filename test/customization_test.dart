import 'dart:convert';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A non-UTF-8 charset used to prove the charset hook is honoured.
class Latin1Charset implements Charset {
  const Latin1Charset();
  @override
  String decode(List<int> bytes) => latin1.decode(bytes);
  @override
  List<int> encode(String s) => latin1.encode(s);
}

/// A form-urlencoded body serializer used to prove serialization is pluggable.
class FormUrlEncodedSerializer implements RequestBodySerializer {
  const FormUrlEncodedSerializer();
  @override
  Object? encode(Object? data) {
    if (data == null) return null;
    if (data is Map) {
      return data.entries
          .map((e) =>
              '${Uri.encodeQueryComponent('${e.key}')}=${Uri.encodeQueryComponent('${e.value}')}')
          .join('&');
    }
    return data.toString();
  }
}

void main() {
  group('Default headers & locale', () {
    test('defaults are unchanged (Accept, Accept-Language: en, Content-Type)',
        () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.post<dynamic>('x', {'a': 1});
      final h = mock.received.single.headers;
      expect(h['Accept'], 'application/json');
      expect(h['Accept-Language'], 'en');
      expect(h['Content-Type'], 'application/json');
    });

    test('custom locale + accept + content-type are applied', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          defaultAccept: 'application/vnd.api+json',
          defaultAcceptLanguage: 'fr-CA',
          defaultContentType: 'application/json; charset=utf-8',
        ),
      );
      await client.post<dynamic>('x', {'a': 1});
      final h = mock.received.single.headers;
      expect(h['Accept'], 'application/vnd.api+json');
      expect(h['Accept-Language'], 'fr-CA');
      expect(h['Content-Type'], 'application/json; charset=utf-8');
    });

    test('defaultHeaders replaces the built-in block entirely', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          defaultHeaders: const {'Accept': 'text/plain', 'X-App': 'demo'},
        ),
      );
      await client.get<dynamic>('x');
      final h = mock.received.single.headers;
      expect(h['Accept'], 'text/plain');
      expect(h['X-App'], 'demo');
      // Accept-Language is no longer injected when defaultHeaders is set.
      expect(h.containsKey('Accept-Language'), false);
    });

    test('per-request headers still override defaults (case-insensitive)',
        () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.get<dynamic>('x',
          options: const RequestOptions(headers: {'accept': 'text/csv'}));
      final h = mock.received.single.headers;
      // The lower-case override replaces the default, not duplicated.
      final acceptKeys =
          h.keys.where((k) => k.toLowerCase() == 'accept').toList();
      expect(acceptKeys.length, 1);
      expect(h[acceptKeys.single], 'text/csv');
    });
  });

  group('Pluggable serialization', () {
    test('default body serialization is byte-identical JSON', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.post<dynamic>('x', {'a': 1, 'b': 'two'});
      expect(mock.received.single.body, utf8.encode('{"a":1,"b":"two"}'));
    });

    test('custom request body serializer is used', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          bodySerializer: const FormUrlEncodedSerializer(),
        ),
      );
      await client.post<dynamic>('x', {'a': 1, 'b': 'two'});
      expect(mock.received.single.body, 'a=1&b=two');
    });

    test('custom charset encodes string bodies', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          charset: const Latin1Charset(),
          bodySerializer:
              const JsonRequestBodySerializer(charset: Latin1Charset()),
        ),
      );
      // 'é' is 0xE9 in latin1 (one byte) vs 0xC3 0xA9 in UTF-8 (two bytes).
      await client.post<dynamic>('x', 'é');
      expect(mock.received.single.body, [0xE9]);
    });

    test('custom response JSON codec is used', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'),
            statusCode: 200, body: {'n': 1});
      var called = false;
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          responseJsonCodec: _SpyJsonCodec(() => called = true),
        ),
      );
      final res = await client.get<Map<String, dynamic>>('x');
      expect(res.isSuccess, true);
      expect(called, true);
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
          queryEncoder:
              const QueryEncoder(listFormat: QueryListFormat.comma),
        ),
      );
      await client.get<dynamic>('x',
          options: const RequestOptions(queryParameters: {
            'ids': [1, 2, 3]
          }));
      expect(mock.received.single.url.query, 'ids=1,2,3');
    });
  });

  group('Retry backoff', () {
    test('custom backoff replaces the exponential formula', () {
      final policy = RetryPolicy(
        useJitter: false,
        backoff: (attempt) => Duration(seconds: attempt * 10),
      );
      expect(policy.delayFor(1, null), const Duration(seconds: 10));
      expect(policy.delayFor(2, null), const Duration(seconds: 20));
    });

    test('custom backoff is still capped at maxDelay', () {
      final policy = RetryPolicy(
        useJitter: false,
        maxDelay: const Duration(seconds: 5),
        backoff: (attempt) => const Duration(seconds: 60),
      );
      expect(policy.delayFor(3, null), const Duration(seconds: 5));
    });

    test('default backoff unchanged (exponential from baseDelay)', () {
      final policy = RetryPolicy(useJitter: false);
      expect(policy.delayFor(1, null), const Duration(milliseconds: 200));
      expect(policy.delayFor(2, null), const Duration(milliseconds: 400));
      expect(policy.delayFor(3, null), const Duration(milliseconds: 800));
    });
  });

  group('Auth header name', () {
    test('default is Authorization', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'tok',
        ),
      );
      await client.get<dynamic>('x');
      expect(mock.received.single.headers['Authorization'], 'Bearer tok');
    });

    test('custom auth header name is honoured', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'tok',
          authHeaderName: 'X-Auth-Token',
        ),
      );
      await client.get<dynamic>('x');
      final h = mock.received.single.headers;
      expect(h['X-Auth-Token'], 'Bearer tok');
      expect(h.containsKey('Authorization'), false);
    });
  });

  group('Success status predicate', () {
    test('default treats 2xx as success, others as failure', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 201, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final res = await client.get<Map<String, dynamic>>('x');
      expect(res.isSuccess, true);
    });

    test('custom predicate can treat 3xx as success', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 302, body: {'redirect': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          isSuccessStatus: (c) => c >= 200 && c < 400,
        ),
      );
      final res = await client.get<Map<String, dynamic>>('x');
      expect(res.isSuccess, true);
      expect(res.data, {'redirect': true});
    });

    test('custom predicate can treat a 2xx as failure', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 204, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          isSuccessStatus: (c) => c == 200,
        ),
      );
      final res = await client.get<dynamic>('x');
      expect(res.isSuccess, false);
      expect(res.statusCode, 204);
    });
  });
}

class _SpyJsonCodec implements ResponseJsonCodec {
  _SpyJsonCodec(this.onCall);
  final void Function() onCall;
  @override
  Object? decode(String source) {
    onCall();
    return jsonDecode(source);
  }
}
