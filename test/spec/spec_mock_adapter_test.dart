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

    test(
        'validates bodies: declared status + body on success, 422 on a '
        'missing required field', () async {
      final spec = ApiSpec(
        title: 'T',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'POST /widgets',
        request: RequestExample(
          schema: Schema.object({
            'name': Schema.string(required: true),
          }),
        ),
        response: const ResponseExample(
          statusCode: 201,
          body: {'id': 'w1'},
        ),
      );

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.test',
          adapter: SpecMockAdapter(spec),
        ),
      );

      final ok = await client.post<Map<String, dynamic>>(
        'widgets',
        {'name': 'gadget'},
      );
      expect(ok.statusCode, 201);
      expect(ok.data, {'id': 'w1'});

      // Missing required field -> schema validation rejects with 422.
      final bad = await client.post<Map<String, dynamic>>('widgets', {});
      expect(bad.statusCode, 422);
      expect(bad.isFailure, isTrue);
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

  group('SpecMockAdapter statusOverrides', () {
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

  group('SpecMockAdapter GraphQL statusOverrides', () {
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

  group('SpecMockAdapter bodyless request validation', () {
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

    test('POST without a body still passes when nothing is required', () async {
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

  group('SpecMockAdapter route matching', () {
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
}
