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
          auth: true,
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
  });
}
