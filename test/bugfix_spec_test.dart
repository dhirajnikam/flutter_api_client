import 'dart:convert';

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
  group('Schema numeric bounds (regression)', () {
    test('integer minimum is enforced', () {
      final schema = Schema.integer(minimum: 1);
      expect(schema.validate(0), isNotEmpty);
      expect(schema.validate(1), isEmpty);
      expect(schema.validate(5), isEmpty);
    });

    test('integer maximum is enforced', () {
      final schema = Schema.integer(maximum: 10);
      expect(schema.validate(11), isNotEmpty);
      expect(schema.validate(10), isEmpty);
    });

    test('number minimum/maximum are enforced', () {
      final schema = Schema.number(minimum: 0.5, maximum: 2.5);
      expect(schema.validate(0.4), isNotEmpty);
      expect(schema.validate(2.6), isNotEmpty);
      expect(schema.validate(1.5), isEmpty);
    });

    test('bounds nested inside an object schema report a path', () {
      final schema = Schema.object({'age': Schema.integer(minimum: 0)});
      final errors = schema.validate({'age': -1});
      expect(errors, isNotEmpty);
      expect(errors.first, contains('age'));
    });

    test('type errors still take precedence over bound checks', () {
      final schema = Schema.integer(minimum: 0);
      expect(schema.validate('not-an-int'), isNotEmpty);
    });
  });

  group('APQ fallback contract (regression)', () {
    // Contract: on a PersistedQueryNotFound miss the client must resend the
    // FULL document together with the same sha256Hash, so the server can
    // register the query. Sending the document without the hash defeats APQ —
    // every later request would miss again. See graphql_client.dart.
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
      final probeHash = ((probe['extensions'] as Map)['persistedQuery']
          as Map)['sha256Hash'];

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
}
