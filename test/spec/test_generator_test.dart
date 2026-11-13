import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

ApiSpec _minimalSpec() => ApiSpec(
      title: 'Test API',
      version: '1.0.0',
      baseUrl: 'https://api.example.com',
    )..group('Users', (g) {
        g.endpoint(
          'GET /users',
          summary: 'List users',
          responses: [
            ResponseExample.ok({'users': []})
          ],
        );
        g.endpoint(
          'GET /users/{id}',
          pathParams: {'id': Schema.integer(required: true)},
          responses: [
            ResponseExample.ok({'id': 1, 'name': 'Alice'})
          ],
        );
      });

ApiSpec _authSpec() => ApiSpec(
      title: 'Auth API',
      version: '1.0.0',
      baseUrl: 'https://api.example.com',
    )..group('Auth', (g) {
        g.endpoint(
          'POST /auth/login',
          auth: false,
          request: RequestExample(
            body: {'email': 'a@b.com', 'password': 'secret'},
            schema: Schema.object({
              'email': Schema.string(required: true),
              'password': Schema.string(minLength: 8, required: true),
            }),
          ),
          responses: [
            ResponseExample.ok({'token': 'jwt'}),
            ResponseExample.error(401, {'message': 'invalid credentials'}),
          ],
        );
      });

ApiSpec _protectedSpec() => ApiSpec(
      title: 'Protected API',
      version: '1.0.0',
      baseUrl: 'https://api.example.com',
    )..group('Items', (g) {
        g.endpoint(
          'POST /items',
          responses: [
            ResponseExample.created({'id': 1})
          ],
        );
      });

void main() {
  group('TestGenerator', () {
    test('output contains void main', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('void main()'));
    });

    test('contains flutter_test import', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains("import 'package:flutter_test/flutter_test.dart'"));
    });

    test('contains flutter_api_client import', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(
        out,
        contains("import 'package:flutter_api_client/flutter_api_client.dart'"),
      );
    });

    test('emits a group per tag', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains("group('Users'"));
    });

    test('emits happy path test for each endpoint', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('GET /users — happy path'));
      expect(out, contains('GET /users/{id} — happy path'));
    });

    test('substitutes concrete value for path param in URL', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains("'users/1'"));
    });

    test('emits schema validation test when request.schema present', () {
      final out = TestGenerator(_authSpec()).generate();
      expect(out, contains('schema validation'));
      expect(out, contains('statusCode, 422'));
    });

    test('emits auth override test when auth == true', () {
      final out = TestGenerator(_protectedSpec()).generate();
      expect(out, contains('auth required'));
      expect(out, contains('statusCode, 401'));
    });

    test('emits error response tests for non-2xx responses', () {
      final out = TestGenerator(_authSpec()).generate();
      expect(out, contains('returns 401'));
    });

    test('no auth override test when auth == false', () {
      final out = TestGenerator(_authSpec()).generate();
      expect(out, isNot(contains('auth required')));
    });

    test('uses baseUrl from spec', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('https://api.example.com'));
    });

    test('includes GENERATED CODE header', () {
      final out = TestGenerator(_minimalSpec()).generate();
      expect(out, contains('GENERATED CODE - DO NOT MODIFY BY HAND'));
    });

    test('supports a custom spec import and symbol', () {
      final out = TestGenerator(
        _minimalSpec(),
        specImport: 'package:flutter_api_client_example/my_spec.dart',
        specSymbol: r'$generatedSpec',
      ).generate();

      expect(
        out,
        contains("import 'package:flutter_api_client_example/my_spec.dart';"),
      );
      expect(out, contains(r'SpecMockAdapter($generatedSpec)'));
    });

    test('output is dart format-clean (no stray blank lines)', () {
      final out = TestGenerator(_authSpec()).generate();
      final lines = out.split('\n');

      // No run of two or more consecutive blank lines.
      expect(out, isNot(contains('\n\n\n')));

      // Exactly one trailing newline — no blank lines at end of file.
      expect(out.endsWith('\n'), isTrue);
      expect(out.endsWith('\n\n'), isFalse);

      // No blank line immediately before a closing brace: `dart format` would
      // strip it, so the generated file would not be format-clean.
      for (var i = 1; i < lines.length; i++) {
        final closesBlock = lines[i].trimLeft().startsWith('}');
        if (closesBlock) {
          expect(lines[i - 1].trim(), isNotEmpty,
              reason:
                  'blank line before "${lines[i].trim()}" at line ${i + 1}');
        }
      }
    });
  });

  group('TestGenerator — special-character escaping', () {
    test('escapes quotes, dollar signs and backslashes in body examples', () {
      final spec = ApiSpec(
        title: 'T',
        version: '1',
        baseUrl: 'https://api.example.com',
      )..group('Items', (g) {
          g.endpoint(
            'POST /items',
            request: const RequestExample(body: {
              'name': "O'Brien",
              'note': r'pa$word',
              'path': r'C:\tmp',
            }),
            responses: [
              ResponseExample.created({'id': 1})
            ],
          );
        });

      final src = TestGenerator(spec).generate();

      // Escaped forms present; the raw (compile-breaking) forms absent.
      expect(src, contains(r"O\'Brien"));
      expect(src, contains(r'pa\$word'));
      expect(src, contains(r'C:\\tmp'));
      expect(src.contains("'O'Brien'"), isFalse);
    });
  });

  group('TestGenerator — unsupported HTTP methods', () {
    test('skips HEAD endpoints instead of emitting client.head()', () {
      final spec = ApiSpec(
        title: 'T',
        version: '1',
        baseUrl: 'https://api.example.com',
      )..group('Ping', (g) {
          g.endpoint('HEAD /ping', responses: [ResponseExample.ok({})]);
        });

      final src = TestGenerator(spec).generate();

      expect(src.contains('client.head'), isFalse);
      expect(src, contains('skipped'));
    });
  });

  group('TestGenerator', () {
    test('schema-validation test goes through the verb call handling', () {
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

    test('no schema-validation test for GET, or when nothing is required', () {
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

    test('escapes quotes in group names, descriptions, paths and baseUrl', () {
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
}
