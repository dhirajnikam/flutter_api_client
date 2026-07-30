import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

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

AdapterRequest _req(String method, String path, {Object? body}) =>
    AdapterRequest(
      method: method,
      url: Uri.parse('https://api.test$path'),
      headers: const {},
      body: body,
      timeout: const Duration(seconds: 5),
    );

Future<Object?> _json(AdapterResponse res) async =>
    res.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));

void main() {
  group('OpenApiGenerator YAML escaping (findings 1 & 2)', () {
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

  group('OpenApiGenerator responses (finding 3)', () {
    test('endpoint without responses emits a default 204', () {
      final spec = ApiSpec(
        title: 'NoResp',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint('DELETE /sessions/current');
      final json = OpenApiGenerator(spec).toJson();
      final op = ((json['paths'] as Map)['/sessions/current']
          as Map)['delete'] as Map<String, Object?>;
      final responses = op['responses'] as Map;
      expect(responses, isNotEmpty);
      expect(responses['204'], {'description': 'No Content'});
    });
  });

  group('OpenApiGenerator servers (finding 4)', () {
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

  group('SpecMockAdapter statusOverrides (finding 5)', () {
    test('override on an endpoint with no declared responses does not throw',
        () async {
      final spec = ApiSpec(
        title: 'Override',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint('DELETE /sessions/current');
      final adapter = SpecMockAdapter(
        spec,
        statusOverrides: const {'DELETE /sessions/current': 401},
      );
      final res = await adapter.send(_req('DELETE', '/sessions/current'));
      expect(res.statusCode, 401);
    });
  });

  group('SpecMockAdapter GraphQL statusOverrides (finding 6)', () {
    test('override takes effect even when the operation declares no errors',
        () async {
      final spec = ApiSpec(
        title: 'GQL',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.graphql((g) {
        g.query(
          'Me',
          document: 'query Me { me { id } }',
          responseExample: const {
            'me': {'id': 1},
          },
        );
      });
      final adapter = SpecMockAdapter(
        spec,
        statusOverrides: const {'GQL Me': 500},
      );
      final res = await adapter.send(_req(
        'POST',
        '/graphql',
        body: jsonEncode({'query': 'query Me { me { id } }'}),
      ));
      expect(res.statusCode, 500);
      final body = await _json(res) as Map;
      final errors = body['errors'] as List;
      expect(errors, isNotEmpty);
      expect((errors.first as Map)['message'], contains('Me'));
    });
  });

  group('SpecMockAdapter bodyless request validation (finding 7)', () {
    test('POST without a body fails validation when schema requires fields',
        () async {
      final spec = ApiSpec(
        title: 'Validate',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'POST /users',
        request: RequestExample(
          schema: Schema.object({
            'name': Schema.string(required: true),
          }),
        ),
        response: ResponseExample.created(const {'id': 1}),
      );
      final adapter = SpecMockAdapter(spec);
      final res = await adapter.send(_req('POST', '/users'));
      expect(res.statusCode, 422);
    });

    test('POST without a body still passes when nothing is required',
        () async {
      final spec = ApiSpec(
        title: 'Validate',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'POST /pings',
        request: RequestExample(
          schema: Schema.object({'note': Schema.string()}),
        ),
        response: ResponseExample.created(const {'id': 1}),
      );
      final adapter = SpecMockAdapter(spec);
      final res = await adapter.send(_req('POST', '/pings'));
      expect(res.statusCode, 201);
    });
  });

  group('SpecMockAdapter route matching (finding 8)', () {
    test('literal segment beats a placeholder declared earlier', () async {
      final spec = ApiSpec(
        title: 'Match',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /users/{id}',
        pathParams: {'id': Schema.integer(required: true)},
        response: ResponseExample.ok(const {'kind': 'by-id'}),
      );
      spec.endpoint(
        'GET /users/me',
        response: ResponseExample.ok(const {'kind': 'me'}),
      );
      final adapter = SpecMockAdapter(spec);

      final me = await adapter.send(_req('GET', '/users/me'));
      expect(await _json(me), {'kind': 'me'});

      // Non-literal paths still resolve to the templated endpoint.
      final byId = await adapter.send(_req('GET', '/users/42'));
      expect(await _json(byId), {'kind': 'by-id'});
    });
  });

  group('TestGenerator (findings 9, 10, 11)', () {
    test('schema-validation test goes through the verb call handling',
        () {
      final spec = ApiSpec(
        title: 'Gen',
        version: '1.0.0',
        baseUrl: 'https://api.example.com',
      );
      spec.endpoint(
        'POST /auth/login',
        request: RequestExample(
          body: const {'email': 'a@b.com'},
          schema: Schema.object({
            'email': Schema.string(required: true),
          }),
        ),
        response: ResponseExample.ok(const {'token': 'jwt'}),
      );
      final out = TestGenerator(spec).generate();
      expect(out, contains('schema validation rejects bad body'));
      expect(
        out,
        contains(
          "await client.post<dynamic>('auth/login', <String, dynamic>{});",
        ),
      );
    });

    test('no schema-validation test for GET, or when nothing is required',
        () {
      final spec = ApiSpec(
        title: 'Gen',
        version: '1.0.0',
        baseUrl: 'https://api.example.com',
      );
      // GET does not carry a body: emitting `client.get('p', {})` would not
      // compile, and the mock would not 422 anyway.
      spec.endpoint(
        'GET /search',
        request: RequestExample(
          schema: Schema.object({
            'q': Schema.string(required: true),
          }),
        ),
        response: ResponseExample.ok(const {'hits': []}),
      );
      // All-optional schema: `{}` validates fine, so the mock would return
      // 201 and the hard-coded 422 assertion would fail.
      spec.endpoint(
        'POST /notes',
        request: RequestExample(
          schema: Schema.object({'text': Schema.string()}),
        ),
        response: ResponseExample.created(const {'id': 1}),
      );
      final out = TestGenerator(spec).generate();
      expect(out, isNot(contains('schema validation rejects bad body')));
      // GET call sites always take a single positional argument.
      expect(out, isNot(contains("client.get<dynamic>('search',")));
    });

    test('QUERY endpoints are generated, not skipped', () {
      final spec = ApiSpec(
        title: 'Gen',
        version: '1.0.0',
        baseUrl: 'https://api.example.com',
      );
      spec.endpoint(
        'QUERY /reports',
        request: const RequestExample(body: {'from': '2026-01-01'}),
        response: ResponseExample.ok(const {'rows': []}),
      );
      final out = TestGenerator(spec).generate();
      expect(out, isNot(contains('skipped')));
      expect(out, contains("await client.query<dynamic>('reports',"));
    });

    test('escapes quotes in group names, descriptions, paths and baseUrl',
        () {
      final spec = ApiSpec(
        title: 'Gen',
        version: '1.0.0',
        baseUrl: "https://api.o'brien.example",
      );
      spec.group("Bob's Endpoints", (g) {
        g.endpoint(
          "GET /o'brien",
          response: ResponseExample.ok(const {'ok': true}),
        );
      });
      final out = TestGenerator(spec).generate();
      expect(out, contains(r"group('Bob\'s Endpoints'"));
      expect(out, contains(r"test('GET /o\'brien — happy path'"));
      expect(out, contains(r"baseUrl: 'https://api.o\'brien.example'"));
      expect(out, contains(r"await client.get<dynamic>('o\'brien');"));
      // No unescaped apostrophe remains inside a generated literal.
      expect(out, isNot(contains("'GET /o'brien")));
    });
  });

  group('BackendGuideGenerator route templates (finding 12)', () {
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

  group('GraphQLClient transport errors (finding 13)', () {
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

  group('Schema enumValues (finding 14)', () {
    test('integer enum is enforced', () {
      const s = Schema(type: 'integer', enumValues: [1, 2, 3]);
      expect(s.validate(2), isEmpty);
      expect(s.validate(9), isNotEmpty);
    });

    test('number enum is enforced', () {
      const s = Schema(type: 'number', enumValues: [0.5, 1.5]);
      expect(s.validate(1.5), isEmpty);
      expect(s.validate(2.5), isNotEmpty);
    });

    test('boolean enum is enforced', () {
      const s = Schema(type: 'boolean', enumValues: [true]);
      expect(s.validate(true), isEmpty);
      expect(s.validate(false), isNotEmpty);
    });

    test('string enum still enforced', () {
      const s = Schema(type: 'string', enumValues: ['a', 'b']);
      expect(s.validate('a'), isEmpty);
      expect(s.validate('c'), isNotEmpty);
    });
  });
}
