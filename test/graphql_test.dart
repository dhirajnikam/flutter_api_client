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

  group('Generators (GraphQL)', () {
    test('Markdown contains GraphQL section', () {
      final md = MarkdownDocGenerator(_gqlSpec()).generate();
      expect(md, contains('## GraphQL'));
      expect(md, contains('`query` Me'));
      expect(md, contains('`mutation` Login'));
      expect(md, contains('```graphql'));
    });

    test('Backend guide contains SDL and resolver skeletons', () {
      final guide = BackendGuideGenerator(
        _gqlSpec(),
        framework: BackendFramework.express,
      ).generate();
      expect(guide, contains('## GraphQL'));
      expect(guide, contains('### Suggested SDL'));
      expect(guide, contains('type Query'));
      expect(guide, contains('type Mutation'));
      expect(guide, contains('login(email: String!, password: String!)'));
      expect(guide, contains('Resolver skeleton'));
      expect(guide, contains('Mutation: {'));
    });
  });
}
