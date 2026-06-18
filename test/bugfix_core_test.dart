import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for bug fixes in work item w4 (core / response / graphql).
///
/// Each group documents the contract violation it guards against. Owner:
/// barbara-liskov. New file — does not touch test/fixes_test.dart or peers'
/// test files.
void main() {
  // ---------------------------------------------------------------------------
  // BUG 1: Success<T>(parsed as T) with a missing decoder threw a raw TypeError
  // that was wrapped as UnknownError. A type mismatch on the success body is a
  // PARSE failure, not an "unknown" one. The sealed-result contract should
  // surface ParseError.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // BUG 2: ApiResult.headers returned const {} for every Failure, silently
  // dropping HttpError.headers (data loss). Header data must be surfaced when
  // the failure carried an HTTP response.
  // ---------------------------------------------------------------------------
  group('Failure.headers surfaces HttpError.headers', () {
    test('HttpError headers are exposed via ApiResult.headers', () {
      const r = Failure<int>(
        HttpError('boom', statusCode: 500, headers: {'x-trace': 'abc'}),
      );
      expect(r.headers, {'x-trace': 'abc'});
    });

    test('transport failure with no response still returns empty headers', () {
      const r = Failure<int>(NetworkError('offline'));
      expect(r.headers, <String, String>{});
    });

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

  // ---------------------------------------------------------------------------
  // BUG 3: buildUri query-merge edge cases — endpoint already carrying a `?`.
  // ---------------------------------------------------------------------------
  group('buildUri query merge', () {
    test('endpoint without query starts with ?', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items',
        queryParameters: {'a': '1'},
      );
      expect(uri.toString(), 'https://api.example.com/items?a=1');
    });

    test('endpoint with existing query appends with &', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items?b=2',
        queryParameters: {'a': '1'},
      );
      expect(uri.toString(), 'https://api.example.com/items?b=2&a=1');
    });

    test('endpoint ending in a bare ? does not produce ?&', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items?',
        queryParameters: {'a': '1'},
      );
      // No stray '&' after the '?'.
      expect(uri.query, 'a=1');
      expect(uri.toString().contains('?&'), false);
    });

    test('no params leaves endpoint untouched', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com/',
        endpoint: '/items',
      );
      expect(uri.toString(), 'https://api.example.com/items');
    });
  });

  // ---------------------------------------------------------------------------
  // BUG 4: CancelToken lacked dispose/listener-cleanup and reuse guards.
  // ---------------------------------------------------------------------------
  group('CancelToken dispose & listener lifecycle', () {
    test('unregister removes the listener', () {
      final token = CancelToken();
      final remove = token.addListener((_) {});
      expect(token.listenerCount, 1);
      remove();
      expect(token.listenerCount, 0);
    });

    test('cancel clears listeners after firing them', () {
      final token = CancelToken();
      var fired = 0;
      token.addListener((_) => fired++);
      token.cancel();
      expect(fired, 1);
      expect(token.listenerCount, 0);
      expect(token.isCancelled, true);
    });

    test('dispose clears listeners without cancelling', () {
      final token = CancelToken();
      var fired = 0;
      token.addListener((_) => fired++);
      token.dispose();
      expect(token.isDisposed, true);
      expect(token.listenerCount, 0);
      expect(fired, 0, reason: 'dispose must not fire listeners');
      expect(token.isCancelled, false);
    });

    test('cancel after dispose is a no-op', () {
      final token = CancelToken();
      token.dispose();
      token.cancel();
      expect(token.isCancelled, false);
    });

    test('addListener after dispose never registers or fires', () {
      final token = CancelToken();
      token.dispose();
      var fired = 0;
      final remove = token.addListener((_) => fired++);
      token.cancel();
      expect(fired, 0);
      expect(token.listenerCount, 0);
      // Returned unregister must be safe to call.
      remove();
    });

    test('whenCancelled does not resolve after dispose-without-cancel',
        () async {
      final token = CancelToken();
      token.dispose();
      var resolved = false;
      // ignore: unawaited_futures
      token.whenCancelled.then((_) => resolved = true);
      await Future<void>.delayed(Duration.zero);
      expect(resolved, false);
    });
  });

  // ---------------------------------------------------------------------------
  // BUG 5: GraphQL — non-object error body cast and missing-decoder cast could
  // throw a TypeError out of query/mutation, violating the GraphQLResponse
  // contract.
  // ---------------------------------------------------------------------------
  group('GraphQL envelope robustness', () {
    test('non-object error body does not throw, returns no envelope', () async {
      final mock = MockAdapter()
        ..onRequest(
            'POST',
            RegExp(r'/graphql$'),
            (_) async => AdapterResponse(
                  statusCode: 500,
                  headers: const {'content-type': 'application/json'},
                  // A JSON array, not a GraphQL envelope object.
                  bodyBytes: Uint8List.fromList(utf8.encode('[1,2,3]')),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final gql = GraphQLClient(client);
      final res = await gql.query<dynamic>('query { x }', includeToken: false);
      expect(res.isSuccess, false);
      expect(res.statusCode, 500);
    });

    test('missing decoder with mismatched data type yields ParseError',
        () async {
      final mock = MockAdapter()
        ..onRequest(
            'POST',
            RegExp(r'/graphql$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {'content-type': 'application/json'},
                  bodyBytes: Uint8List.fromList(
                    utf8.encode('{"data":{"me":{"id":1}}}'),
                  ),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final gql = GraphQLClient(client);
      // Request a String while data is a Map, no decoder.
      final res = await gql.query<String>('query { me }', includeToken: false);
      expect(res.isSuccess, false);
      expect(res.networkError, isA<ParseError>());
    });
  });

  // ---------------------------------------------------------------------------
  // BUG 6: GraphQL APQ miss handling — only `PersistedQueryNotFound` message was
  // detected. Must also fall back on `PersistedQueryNotSupported` and on the
  // canonical extensions.code values.
  // ---------------------------------------------------------------------------
  group('GraphQL APQ miss detection', () {
    Future<AdapterResponse> persistedThenFull(AdapterRequest req) async {
      final payload =
          jsonDecode(utf8.decode(req.body as List<int>? ?? const []))
              as Map<String, dynamic>;
      final hasQuery = payload['query'] != null;
      if (!hasQuery) {
        // First (persisted-only) attempt: signal a miss.
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode({
            'errors': [
              {
                'message': 'whatever',
                'extensions': {'code': 'PERSISTED_QUERY_NOT_FOUND'},
              }
            ],
          }))),
        );
      }
      // Full document follow-up: succeed.
      return AdapterResponse(
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode({
          'data': {'ok': true},
        }))),
      );
    }

    test('falls back to full document on extensions.code miss', () async {
      final mock = MockAdapter()
        ..onRequest('POST', RegExp(r'/graphql$'), persistedThenFull);
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final gql = GraphQLClient(client, usePersistedQueries: true);
      final res = await gql.query<Map<String, dynamic>>(
        'query Q { ok }',
        includeToken: false,
      );
      expect(res.isSuccess, true);
      expect(res.data, {'ok': true});
    });

    test('falls back on PersistedQueryNotSupported message', () async {
      var calls = 0;
      final mock = MockAdapter()
        ..onRequest('POST', RegExp(r'/graphql$'), (req) async {
          calls++;
          final payload =
              jsonDecode(utf8.decode(req.body as List<int>? ?? const []))
                  as Map;
          if (payload['query'] == null) {
            return AdapterResponse(
              statusCode: 200,
              headers: const {'content-type': 'application/json'},
              bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode({
                'errors': [
                  {'message': 'PersistedQueryNotSupported'}
                ],
              }))),
            );
          }
          return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode({
              'data': {'ok': true},
            }))),
          );
        });
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final gql = GraphQLClient(client, usePersistedQueries: true);
      final res = await gql.query<Map<String, dynamic>>(
        'query Q { ok }',
        includeToken: false,
      );
      expect(res.isSuccess, true);
      expect(calls, 2, reason: 'must retry with full document');
    });
  });

  // ---------------------------------------------------------------------------
  // BUG 7: ResponseHandler HTML/text classification was case-sensitive and
  // missed lowercase / attributed doctypes.
  // ---------------------------------------------------------------------------
  group('ResponseHandler HTML classification', () {
    const handler = ResponseHandler();

    test('lowercase doctype is classified as HTML', () {
      expect(
          handler.isHtmlOrTextResponse('<!doctype html><html></html>'), true);
    });

    test('uppercase HTML tag is classified as HTML', () {
      expect(handler.isHtmlOrTextResponse('<HTML><body>x</body></HTML>'), true);
    });

    test('doctype with attributes is classified as HTML', () {
      expect(
        handler.isHtmlOrTextResponse('<!DOCTYPE html PUBLIC "...">'),
        true,
      );
    });

    test('JSON object is not classified as HTML', () {
      expect(handler.isHtmlOrTextResponse('{"a":1}'), false);
    });
  });

  // ---------------------------------------------------------------------------
  // BUG 8 (w1 / margaret-hamilton): an explicit `includeToken: false` method
  // argument was silently overridden by the RequestOptions default (`true`)
  // whenever a non-null `options` was supplied — leaking the Authorization
  // header onto a request the caller had explicitly excluded. Suppressing the
  // token is a deliberate security decision; the fail-safe rule is that the
  // token attaches only when BOTH knobs permit it.
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // BUG 9 (w1 / margaret-hamilton): header merge keyed by the literal string
  // emitted BOTH the default `Content-Type` and a caller override like
  // `content-type`, putting two conflicting Content-Type headers on the wire
  // (RFC 7230 §3.2 — header names are case-insensitive). The merge must be
  // case-insensitive: a later source replaces an earlier same-named header
  // regardless of casing.
  // ---------------------------------------------------------------------------
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

    test('default Content-Type preserved when no override', () async {
      final mock = MockAdapter()
        ..onRequest(
            'POST',
            RegExp(r'/y$'),
            (_) async => AdapterResponse(
                  statusCode: 200,
                  headers: const {},
                  bodyBytes: Uint8List.fromList(utf8.encode('{}')),
                ));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.post<dynamic>('y', {'a': 1});
      expect(mock.received.single.headers['Content-Type'], 'application/json');
    });
  });
}
