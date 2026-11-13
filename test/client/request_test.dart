import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Bespoke HttpAdapter — a transport substitute with ZERO ties to MockAdapter /
// DefaultHttpAdapter. Records calls and replays scripted responses.
// ---------------------------------------------------------------------------
class _ScriptedAdapter implements HttpAdapter {
  _ScriptedAdapter(this._script);

  final AdapterResponse Function(AdapterRequest req) _script;
  final List<AdapterRequest> seen = [];
  int closed = 0;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    seen.add(request);
    return _script(request);
  }

  @override
  void close() => closed++;
}

AdapterResponse _json(int status, Object body,
        {Map<String, String> headers = const {}}) =>
    AdapterResponse(
      statusCode: status,
      headers: {'content-type': 'application/json', ...headers},
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );

void main() {
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

    test('applies decoder to non-2xx scalar JSON bodies', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/typed-scalar-error$'),
            statusCode: 422, body: true);
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.get<String>(
        'typed-scalar-error',
        decoder: (json) => (json as bool) ? 'yes' : 'no',
      );

      expect(result.isFailure, true);
      final error = (result as Failure<String>).error as HttpError;
      expect(error.body, 'yes');
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

    test('returns Failure with ParseError on malformed JSON success body',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/broken-json$'),
            (_) async => AdapterResponse(
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

    test('decoder failure on 200 returns Failure with ParseError', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/bad-decode$'), statusCode: 200, body: {'id': 7});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      final result = await client.get<String>(
        'bad-decode',
        decoder: (_) => throw StateError('boom'),
      );

      expect(result.isFailure, true);
      expect((result as Failure<String>).error, isA<ParseError>());
      expect(result.statusCode, 200);
    });

    test('returns Failure with ParseError on text body for JSON response',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/html$'),
            (_) async => AdapterResponse(
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
        ..onRequest(
            'GET',
            RegExp(r'/scalar$'),
            (_) async => AdapterResponse(
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

    test('returns Failure with ParseError on invalid utf8 success body',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/invalid-utf8-success$'),
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
      expect(result.statusCode, 200);
    });

    test('returns Success with null data on empty successful JSON body',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/no-content$'),
            (_) async => AdapterResponse(
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
        ..onRequest(
            'GET',
            RegExp(r'/server-error$'),
            (_) async => AdapterResponse(
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
        ..onRequest(
            'GET',
            RegExp(r'/invalid-utf8-error$'),
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

  group('Per-request policy override', () {
    test('CacheInterceptor honours a per-request CachePolicy override',
        () async {
      var hits = 0;
      final adapter = _ScriptedAdapter((req) {
        hits++;
        return _json(200, {'v': hits});
      });
      final store = MemoryCacheStore();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: adapter,
          interceptors: [CacheInterceptor(store: store)],
        ),
      );
      // No defaultPolicy: the per-request policy is what activates caching.
      final opts = RequestOptions(cachePolicy: CachePolicy.cacheFirst());
      await client.get<Map<String, dynamic>>('x', options: opts);
      await client.get<Map<String, dynamic>>('x', options: opts);
      expect(hits, 1);
    });
  });

  // A type mismatch on the success body is a parse failure, so it must surface
  // as ParseError rather than a raw TypeError wrapped as UnknownError.
  group('missing-decoder cast on Success', () {
    test('object body cast to concrete type yields ParseError, not Unknown',
        () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/user$'), statusCode: 200, body: {'name': 'Bob'});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      // No decoder for a concrete type whose runtime value is a Map.
      final result = await client.get<String>('user');

      expect(result.isFailure, true);
      final error = (result as Failure<String>).error;
      expect(error, isA<ParseError>(),
          reason: 'must be ParseError, not UnknownError');
      expect(result.statusCode, 200);
    });

    test('matching primitive type without decoder still succeeds', () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/n$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {'content-type': 'application/json'},
                  bodyBytes: Uint8List.fromList(utf8.encode('42')),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      final result = await client.get<int>('n');
      expect(result.isSuccess, true);
      expect(result.data, 42);
    });
  });

  // Dropping HttpError.headers on a Failure is data loss (e.g. Retry-After):
  // headers must be surfaced whenever the failure carried an HTTP response.
  group('Failure.headers surfaces HttpError.headers', () {
    test('end-to-end: response headers reach the Failure', () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/err$'),
            (_) async => AdapterResponse(
                  statusCode: 503,
                  headers: const {
                    'content-type': 'application/json',
                    'retry-after': '120',
                  },
                  bodyBytes:
                      Uint8List.fromList(utf8.encode('{"message":"down"}')),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final result = await client.get<dynamic>('err');
      expect(result.isFailure, true);
      expect(result.headers['retry-after'], '120');
    });
  });

  // Suppressing the token is a deliberate security decision, so the fail-safe
  // rule is that it attaches only when BOTH knobs permit it: an explicit
  // `includeToken: false` method argument must not be overridden by the
  // RequestOptions default (`true`) when `options` is also supplied.
  group('includeToken fail-safe (method arg vs options)', () {
    ApiClient build(MockAdapter mock) => ApiClient(ApiClientConfig(
          baseUrl: 'https://api.example.com',
          getAccessToken: () async => 'SECRET',
          adapter: mock,
        ));

    test('method includeToken:false wins even when options is present',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/me$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {},
                  bodyBytes: Uint8List.fromList(utf8.encode('{"ok":true}')),
                ));
      final client = build(mock);
      await client.get<dynamic>(
        'me',
        includeToken: false,
        options: const RequestOptions(headers: {'X-Foo': 'bar'}),
      );
      expect(mock.received.single.headers.containsKey('Authorization'), false,
          reason: 'token must not leak onto an explicitly excluded request');
    });

    test('options includeToken:false suppresses token (default method arg)',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/me$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {},
                  bodyBytes: Uint8List.fromList(utf8.encode('{"ok":true}')),
                ));
      final client = build(mock);
      await client.get<dynamic>(
        'me',
        options: const RequestOptions(includeToken: false),
      );
      expect(mock.received.single.headers.containsKey('Authorization'), false);
    });

    test('both default true still attaches the token', () async {
      final mock = MockAdapter()
        ..onRequest(
            'GET',
            RegExp(r'/me$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {},
                  bodyBytes: Uint8List.fromList(utf8.encode('{"ok":true}')),
                ));
      final client = build(mock);
      await client.get<dynamic>('me');
      expect(mock.received.single.headers['Authorization'], 'Bearer SECRET');
    });
  });

  // Header names are case-insensitive (RFC 7230 §3.2), so a caller override
  // like `content-type` must replace the default `Content-Type` instead of
  // putting two conflicting headers on the wire.
  group('case-insensitive header merge', () {
    test('caller content-type override replaces the default, not duplicates',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'POST',
            RegExp(r'/x$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {},
                  bodyBytes: Uint8List.fromList(utf8.encode('{}')),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.post<dynamic>(
        'x',
        {'a': 1},
        options:
            const RequestOptions(headers: {'content-type': 'application/xml'}),
      );
      final sent = mock.received.single.headers;
      final ctKeys =
          sent.keys.where((k) => k.toLowerCase() == 'content-type').toList();
      expect(ctKeys.length, 1, reason: 'exactly one Content-Type header');
      expect(sent[ctKeys.single], 'application/xml',
          reason: 'caller override must win');
    });
  });
}
