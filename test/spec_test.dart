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

void main() {
  group('ApiSpec', () {
    test('records endpoints', () {
      final spec = _sampleSpec();
      expect(spec.endpoints, hasLength(2));
      expect(spec.endpoints.first.method, 'POST');
      expect(spec.endpoints.first.tag, 'Auth');
    });
    test('builds path pattern', () {
      final spec = _sampleSpec();
      final ep = spec.endpoints[1];
      expect(ep.pathPattern.hasMatch('/users/42'), true);
      expect(ep.pathPattern.hasMatch('/users/'), false);
    });
  });

  group('SpecMockAdapter', () {
    test('drives ApiClient end-to-end', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com/api/v1',
          adapter: SpecMockAdapter(_sampleSpec()),
        ),
      );
      final res = await client.post<Map<String, dynamic>>(
          'auth/login',
          const {
            'email': 'a@b.com',
            'password': 'secret123',
          },
          includeToken: false);
      expect(res.isSuccess, true);
      expect(res.data, contains('token'));
    });

    test('returns 422 when body fails schema', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com/api/v1',
          adapter: SpecMockAdapter(_sampleSpec()),
        ),
      );
      final res = await client.post<dynamic>(
          'auth/login',
          const {
            'email': 'a@b.com',
            'password': 'x',
          },
          includeToken: false);
      expect(res.statusCode, 422);
    });

    test('honours status overrides', () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com/api/v1',
          adapter: SpecMockAdapter(
            _sampleSpec(),
            statusOverrides: const {'POST /auth/login': 401},
          ),
        ),
      );
      final res = await client.post<dynamic>(
          'auth/login',
          const {
            'email': 'a@b.com',
            'password': 'secret123',
          },
          includeToken: false);
      expect(res.statusCode, 401);
    });

    test(
        'statusOverrides can force a status without a matching response example',
        () async {
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com/api/v1',
          adapter: SpecMockAdapter(
            _sampleSpec(),
            statusOverrides: const {'GET /users/{id}': 401},
          ),
        ),
      );
      final res = await client.get<dynamic>('users/1');
      expect(res.statusCode, 401);
    });
  });

  group('Generators', () {
    test('OpenAPI YAML contains routes', () {
      final yaml = OpenApiGenerator(_sampleSpec()).toYaml();
      expect(yaml, contains('/auth/login'));
      expect(yaml, contains('/users/{id}'));
      expect(yaml, contains('openapi: 3.1.0'));
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
      // Regression: the YAML serialiser used to drop keys whose value was an
      // empty list/map, silently diverging from the JSON document.
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

  group('Schema validation', () {
    test('object required', () {
      final s = Schema.object({
        'email': Schema.string(required: true),
        'age': Schema.integer(),
      });
      expect(s.validate({'email': 'a@b.com'}), isEmpty);
      expect(s.validate({'age': 5}), isNotEmpty);
    });
    test('type mismatch', () {
      final s = Schema.integer(required: true);
      expect(s.validate('hello'), isNotEmpty);
    });
  });
}
