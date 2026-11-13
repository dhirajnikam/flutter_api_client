import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Object? _bodyJson(AdapterRequest req) {
  final b = req.body;
  if (b is String) return jsonDecode(b);
  if (b is List<int>) return jsonDecode(utf8.decode(b));
  return b;
}

void main() {
  // An APQ miss is signalled either by message (`PersistedQueryNotFound`,
  // `PersistedQueryNotSupported`) or by the canonical extensions.code values;
  // all of them must fall back to sending the full document.
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

  group('APQ fallback contract', () {
    // Contract: on a PersistedQueryNotFound miss the client must resend the
    // FULL document together with the same sha256Hash, so the server can
    // register the query. Sending the document without the hash defeats APQ —
    // every later request would miss again.
    const document = r'query Me { me { id name } }';

    ApiSpec gqlSpec() {
      final spec = ApiSpec(
        title: 'GQL',
        version: '1.0.0',
        baseUrl: 'https://api.example.com',
      );
      spec.graphql((g) {
        g.query(
          'Me',
          document: document,
          responseExample: const {
            'me': {'id': 1, 'name': 'Alice'},
          },
        );
      });
      return spec;
    }

    test('fallback request carries both the document and the persisted hash',
        () async {
      final adapter = SpecMockAdapter(gqlSpec());
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: adapter,
        ),
      );
      final gql = GraphQLClient(client, usePersistedQueries: true);

      final res = await gql.query<String>(
        document,
        decoder: (data) => (data as Map)['me']['name'] as String,
        includeToken: false,
      );
      expect(res.isSuccess, true);
      expect(res.data, 'Alice');

      // Two requests: the hash-only probe, then the full fallback.
      expect(adapter.received, hasLength(2));

      final probe = _bodyJson(adapter.received[0]) as Map;
      expect(probe.containsKey('query'), isFalse,
          reason: 'probe must send hash only, never the document');
      final probeHash =
          ((probe['extensions'] as Map)['persistedQuery'] as Map)['sha256Hash'];

      final fallback = _bodyJson(adapter.received[1]) as Map;
      expect(fallback['query'], document,
          reason: 'fallback must include the full document');
      final fallbackHash = ((fallback['extensions'] as Map)['persistedQuery']
          as Map)['sha256Hash'];

      // Both requests use the SHA-256 hex digest required by the APQ protocol,
      // and the fallback re-sends the same hash so the server registers it.
      final expected = sha256.convert(utf8.encode(document)).toString();
      expect(probeHash, expected);
      expect(fallbackHash, expected);
    });
  });

  group('GraphQL APQ default hash', () {
    test('sends a real SHA-256 hex digest of the document', () async {
      const document = 'query { viewer { id } }';
      String? sentHash;
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/graphql$'), (req) async {
        final body = jsonDecode(utf8.decode(req.body as List<int>))
            as Map<String, dynamic>;
        final pq = (body['extensions'] as Map)['persistedQuery'] as Map;
        sentHash = pq['sha256Hash'] as String?;
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: Uint8List.fromList(
            utf8.encode(jsonEncode({
              'data': {
                'viewer': {'id': '1'}
              }
            })),
          ),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      final gql = GraphQLClient(client, usePersistedQueries: true);
      await gql.query<dynamic>(document);

      // `printf '%s' 'query { viewer { id } }' | shasum -a 256`
      expect(
        sentHash,
        '2bc37c1266cb1ed845971009ea0e370dd1a7d12ae34940fcfa714229e7126d02',
      );
    });
  });
}
