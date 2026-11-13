import 'dart:convert';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

ApiSpec _sampleSpec() {
  final spec = ApiSpec(
    title: 'Sample',
    version: '1.0.0',
    baseUrl: 'https://api.example.com/api/v1',
  );
  spec.group('Auth', (g) {
    g.endpoint(
      'POST /auth/login',
      summary: 'Log in',
      auth: false,
      request: RequestExample(
        body: const {'email': 'a@b.com', 'password': 'secret123'},
        schema: Schema.object({
          'email': Schema.string(format: 'email', required: true),
          'password': Schema.string(minLength: 8, required: true),
        }),
      ),
      responses: [
        ResponseExample.ok(const {
          'token': 'jwt',
          'user': {'id': 1},
        }),
        ResponseExample.error(401, const {'message': 'invalid credentials'}),
      ],
    );
  });
  spec.group('Users', (g) {
    g.endpoint(
      'GET /users/{id}',
      summary: 'Get user',
      pathParams: {'id': Schema.integer(required: true)},
      response: ResponseExample.ok(const {'id': 1, 'name': 'A'}),
    );
  });
  return spec;
}

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

void main() {
  group('OpenApiGenerator YAML escaping', () {
    test('escapes backslashes, quotes and control chars in scalars', () {
      final spec = ApiSpec(
        title: 'Esc',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /codes',
        description: r'Must match ^\d{4}$',
        summary: 'line1\nline2\tand "quoted"',
        response: ResponseExample.ok(const {'ctl': 'a\x01b'}),
      );
      final yaml = OpenApiGenerator(spec).toYaml();
      // Backslash escaped first, then the string is double-quoted.
      expect(yaml, contains(r'description: "Must match ^\\d{4}$"'));
      // Newline, tab and inner quotes become proper YAML escapes.
      expect(yaml, contains(r'summary: "line1\nline2\tand \"quoted\""'));
      // Other control chars (< 0x20) use \xXX escapes.
      expect(yaml, contains(r'ctl: "a\x01b"'));
      // No raw newline leaked into the emitted scalar.
      expect(yaml, isNot(contains('summary: "line1\nline2')));
    });

    test('quotes string values that look like other YAML scalar types', () {
      final spec = ApiSpec(
        title: 'Typed',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /flags',
        response: ResponseExample.ok(const {
          'code': '200',
          'ratio': '1.5',
          'tilde': '~',
          'toggle': 'on',
          'off_toggle': 'off',
          'bool_like': 'Yes',
        }),
      );
      final yaml = OpenApiGenerator(spec).toYaml();
      expect(yaml, contains('code: "200"'));
      expect(yaml, contains('ratio: "1.5"'));
      expect(yaml, contains('tilde: "~"'));
      expect(yaml, contains('toggle: "on"'));
      expect(yaml, contains('off_toggle: "off"'));
      expect(yaml, contains('bool_like: "Yes"'));
      // Multi-dot version strings are not numbers and stay plain.
      expect(yaml, contains('openapi: 3.1.0'));
    });

    test('quotes numeric-looking map keys (status codes stay strings)', () {
      final spec = ApiSpec(
        title: 'Keys',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /ping',
        response: ResponseExample.ok(const {'ok': true}),
      );
      final yaml = OpenApiGenerator(spec).toYaml();
      // The response map key '200' must stay a string when the YAML is loaded.
      expect(yaml, contains('"200":'));
      expect(yaml, isNot(contains('\n        200:')));
    });
  });

  group('OpenApiGenerator responses', () {
    test('endpoint without responses emits a default 204', () {
      final spec = ApiSpec(
        title: 'NoResp',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint('DELETE /sessions/current');
      final json = OpenApiGenerator(spec).toJson();
      final op = ((json['paths'] as Map)['/sessions/current'] as Map)['delete']
          as Map<String, Object?>;
      final responses = op['responses'] as Map;
      expect(responses, isNotEmpty);
      expect(responses['204'], {'description': 'No Content'});
    });
  });

  group('OpenApiGenerator servers', () {
    test('baseUrl is always emitted first, then extra servers', () {
      final spec = ApiSpec(
        title: 'Servers',
        version: '1.0.0',
        baseUrl: 'https://api.test',
        servers: const ['https://staging.api.test'],
      );
      final servers = OpenApiGenerator(spec).toJson()['servers'] as List;
      expect(servers, [
        {'url': 'https://api.test'},
        {'url': 'https://staging.api.test'},
      ]);
    });

    test('a server duplicating baseUrl is not emitted twice', () {
      final spec = ApiSpec(
        title: 'Servers',
        version: '1.0.0',
        baseUrl: 'https://api.test',
        servers: const ['https://api.test', 'https://eu.api.test'],
      );
      final servers = OpenApiGenerator(spec).toJson()['servers'] as List;
      expect(servers, [
        {'url': 'https://api.test'},
        {'url': 'https://eu.api.test'},
      ]);
    });
  });

  group('BackendGuideGenerator route templates', () {
    ApiSpec buildSpec() {
      final spec = ApiSpec(
        title: 'Guide',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /users/{id}',
        pathParams: {'id': Schema.integer(required: true)},
        response: ResponseExample.ok(const {'id': 1}),
      );
      return spec;
    }

    test('FastAPI snippets use {param} templates', () {
      final md = BackendGuideGenerator(
        buildSpec(),
        framework: BackendFramework.fastapi,
      ).generate();
      expect(md, contains("@app.get('/users/{id}')"));
      expect(md, isNot(contains("@app.get('/users/:id')")));
    });

    test('Express and Gin snippets keep :param segments', () {
      final express = BackendGuideGenerator(
        buildSpec(),
        framework: BackendFramework.express,
      ).generate();
      expect(express, contains("app.get('/users/:id'"));

      final gin = BackendGuideGenerator(
        buildSpec(),
        framework: BackendFramework.gin,
      ).generate();
      expect(gin, contains('r.GET("/users/:id"'));
    });
  });

  group('Generators', () {
    test('OpenAPI YAML contains routes', () {
      final yaml = OpenApiGenerator(_sampleSpec()).toYaml();
      expect(yaml, contains('/auth/login'));
      expect(yaml, contains('/users/{id}'));
      expect(yaml, contains('openapi: 3.1.0'));
    });

    test('OpenApiGenerator round-trips a spec into a 3.1 document', () {
      final spec = ApiSpec(
        title: 'Docs',
        version: '2.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /ping',
        response: const ResponseExample(statusCode: 200, body: {'pong': true}),
      );
      final doc = OpenApiGenerator(spec).toJson();
      expect(doc['openapi'], '3.1.0');
      expect((doc['paths'] as Map).containsKey('/ping'), isTrue);
      // Generator output must be valid JSON (serializable) — contract for docs.
      expect(() => jsonEncode(doc), returnsNormally);
    });

    test('OpenAPI YAML preserves empty arrays in example payloads', () {
      final spec = ApiSpec(
        title: 'Empties',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /users',
        response: ResponseExample.ok(const {'users': [], 'total': 0}),
      );
      final yaml = OpenApiGenerator(spec).toYaml();
      // Dropping keys whose value is an empty list/map would make the YAML
      // diverge from the JSON document.
      expect(yaml, contains('users: []'));
      expect(yaml, contains('total: 0'));
    });

    test(
        'OpenAPI keeps security:[] for public endpoints and omits null summary',
        () {
      final spec = ApiSpec(
        title: 'Public',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      // No summary, and auth:false => must emit `security: []` (OpenAPI's
      // "this operation is public") in both JSON and YAML.
      spec.endpoint('GET /health', auth: false);
      final json = OpenApiGenerator(spec).toJson();
      final op =
          (json['paths'] as Map)['/health']['get'] as Map<String, Object?>;
      expect(op.containsKey('security'), isTrue);
      expect(op['security'], isEmpty);
      // A null summary must not be serialised as `"summary": null`.
      expect(op.containsKey('summary'), isFalse);

      final yaml = OpenApiGenerator(spec).toYaml();
      expect(yaml, contains('security: []'));
      expect(yaml, isNot(contains('summary: null')));
    });

    test('Markdown contains tags + endpoints', () {
      final md = MarkdownDocGenerator(_sampleSpec()).generate();
      expect(md, contains('# Sample — API Reference'));
      expect(md, contains('POST /auth/login'));
      expect(md, contains('Auth: public'));
    });

    test('Backend guide contains route table and skeleton', () {
      final md = BackendGuideGenerator(
        _sampleSpec(),
        framework: BackendFramework.express,
      ).generate();
      expect(md, contains('Route table'));
      expect(md, contains('Handler skeleton'));
      expect(md, contains("app.post('/auth/login'"));
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
