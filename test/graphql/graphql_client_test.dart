import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

ApiSpec _gqlSpec() {
  final spec = ApiSpec(
    title: 'GQL Demo',
    version: '1.0.0',
    baseUrl: 'https://api.example.com',
  );
  spec.graphql((g) {
    g.query(
      'Me',
      document: r'query Me { me { id name } }',
      responseExample: const {
        'me': {'id': 1, 'name': 'Alice'},
      },
    );
    g.mutation(
      'Login',
      document: r'''
        mutation Login($email: String!, $password: String!) {
          login(email: $email, password: $password) { token }
        }
      ''',
      variables: {
        'email': Schema.string(required: true, format: 'email'),
        'password': Schema.string(required: true, minLength: 8),
      },
      responseExample: const {
        'login': {'token': 'jwt-token'},
      },
      errors: const [
        GraphQLErrorExample(
          message: 'Invalid credentials',
          extensions: {'code': 'UNAUTHENTICATED'},
        ),
      ],
    );
  });
  return spec;
}

ApiClient _buildClient(ApiSpec spec) => ApiClient(
      ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: SpecMockAdapter(spec),
      ),
    );

/// Adapter that returns a canned response for every request — used to poke
/// transport failures (non-JSON bodies) through the GraphQL client.
class _FixedAdapter implements HttpAdapter {
  _FixedAdapter(this.statusCode, this.contentType, this.body);

  final int statusCode;
  final String contentType;
  final String body;

  @override
  Future<AdapterResponse> send(AdapterRequest req) async => AdapterResponse(
        statusCode: statusCode,
        headers: {'content-type': contentType},
        bodyBytes: Uint8List.fromList(utf8.encode(body)),
      );

  @override
  void close() {}
}

void main() {
  group('GraphQLClient + SpecMockAdapter', () {
    test('query returns decoded data', () async {
      final gql = GraphQLClient(_buildClient(_gqlSpec()));
      final res = await gql.query<String>(
        r'query Me { me { id name } }',
        decoder: (data) => (data as Map)['me']['name'] as String,
        includeToken: false,
      );
      expect(res.isSuccess, true);
      expect(res.data, 'Alice');
      expect(res.errors, isEmpty);
    });

    test('query without a decoder returns the raw data map', () async {
      final gql = GraphQLClient(_buildClient(_gqlSpec()));
      final res = await gql.query<Map<String, dynamic>>(
        r'query Me { me { id name } }',
      );
      expect(res.isSuccess, isTrue);
      expect(res.data, {
        'me': {'id': 1, 'name': 'Alice'}
      });
      expect(res.errors, isEmpty);
    });

    test('mutation success', () async {
      final gql = GraphQLClient(_buildClient(_gqlSpec()));
      final res = await gql.mutation<Map<String, dynamic>>(
        r'''mutation Login($email: String!, $password: String!) {
              login(email: $email, password: $password) { token }
            }''',
        variables: const {'email': 'a@b.com', 'password': 'secret123'},
        includeToken: false,
      );
      expect(res.isSuccess, true);
      expect(res.data!['login']['token'], 'jwt-token');
    });

    test('variable validation produces GraphQL error', () async {
      final gql = GraphQLClient(_buildClient(_gqlSpec()));
      final res = await gql.mutation<dynamic>(
        r'''mutation Login($email: String!, $password: String!) {
              login(email: $email, password: $password) { token }
            }''',
        variables: const {'email': 'a@b.com', 'password': 'short'},
        includeToken: false,
      );
      expect(res.isSuccess, false);
      expect(res.errors, isNotEmpty);
      expect(res.errors.first.extensions?['code'], 'BAD_USER_INPUT');
    });

    test('unknown operation returns OPERATION_NOT_FOUND', () async {
      final gql = GraphQLClient(_buildClient(_gqlSpec()));
      final res = await gql.query<dynamic>(
        r'query Unknown { whatever { x } }',
        includeToken: false,
      );
      expect(res.isSuccess, false);
      expect(res.errors.first.extensions?['code'], 'OPERATION_NOT_FOUND');
    });

    test('statusOverrides force GraphQL error response', () async {
      final spec = _gqlSpec();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: SpecMockAdapter(
            spec,
            statusOverrides: const {'GQL Login': 401},
          ),
        ),
      );
      final gql = GraphQLClient(client);
      final res = await gql.mutation<dynamic>(
        r'''mutation Login($email: String!, $password: String!) {
              login(email: $email, password: $password) { token }
            }''',
        variables: const {'email': 'a@b.com', 'password': 'secret123'},
        includeToken: false,
      );
      expect(res.isSuccess, false);
      expect(res.statusCode, 401);
      expect(res.errors.first.message, contains('Invalid credentials'));
    });
  });

  // query/mutation must never throw a TypeError: a non-object body or a data
  // type mismatch has to come back inside the GraphQLResponse.
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

  group('GraphQLClient transport errors', () {
    test('non-JSON 200 body surfaces the underlying error', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.test',
          adapter: _FixedAdapter(
            200,
            'text/html',
            '<html>captive portal</html>',
          ),
        ),
      );
      final res = await GraphQLClient(client).query<dynamic>(
        'query Me { me { id } }',
        includeToken: false,
      );
      expect(res.isSuccess, false);
      expect(res.networkError, isNotNull);
    });

    test('non-object error body surfaces the underlying error', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.test',
          adapter: _FixedAdapter(502, 'text/html', 'Bad Gateway'),
        ),
      );
      final res = await GraphQLClient(client).query<dynamic>(
        'query Me { me { id } }',
        includeToken: false,
      );
      expect(res.isSuccess, false);
      expect(res.networkError, isNotNull);
    });
  });

  test('a transport failure keeps its type', () async {
    final mock = MockAdapter()
      ..onRequest('POST', RegExp(r'/graphql$'),
          (_) async => throw const TimeoutError('slow'));
    final gql = GraphQLClient(
      ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
      )),
    );

    final res = await gql.query<dynamic>('query { me { id } }');

    expect(res.isSuccess, isFalse);
    expect(res.networkError, isA<TimeoutError>());
  });
}
