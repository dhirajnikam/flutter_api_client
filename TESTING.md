# Testing Cheat-Sheet

Quick reference for testing code that uses `flutter_api_client`.

---

## MockAdapter — manual stubs

Full control over every response. Use when you don't have an `ApiSpec`.

```dart
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GET /users returns list', () async {
    final adapter = MockAdapter()
      ..stub('GET', '/users', statusCode: 200, body: {'users': []});

    final client = ApiClient(ApiClientConfig.test(
      baseUrl: 'https://api.example.com',
      adapter: adapter,
    ));

    final result = await client.get<Map<String, dynamic>>('users');
    expect(result.isSuccess, true);
    expect(result.data, contains('users'));
  });
}
```

---

## SpecMockAdapter — spec-driven mock

Automatically matches routes, validates request bodies, and returns the response examples defined in your `ApiSpec`.

```dart
final client = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com',
  adapter: SpecMockAdapter(myApiSpec),
));

// Happy path
final res = await client.get<Map<String, dynamic>>('users');
expect(res.isSuccess, true);

// Force a specific status code
final client401 = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com',
  adapter: SpecMockAdapter(myApiSpec,
    statusOverrides: const {'GET /users': 401},
  ),
));
expect((await client401.get<dynamic>('users')).statusCode, 401);

// Schema validation — invalid body returns 422
final res3 = await client.post<dynamic>('users', {});
expect(res3.statusCode, 422);
```

---

## Generated test scaffold (.test.g.dart)

After `dart run build_runner build`, you get `lib/my_api.test.g.dart` — a minimal smoke test that confirms your spec loads and all endpoints are registered.

```bash
dart test lib/my_api.test.g.dart
```

---

## Full generated test suite

```bash
dart run flutter_api_client:gen --only tests
# Writes: test/api_spec_test.dart
```

Covers happy path, schema validation failures, auth checks, and error responses for every endpoint. Safe to customise — won't be overwritten unless you re-run the command.

---

## Running tests

```bash
# All tests, 8 workers in parallel
dart test --concurrency=8

# Single file
dart test test/api_spec_test.dart

# Filter by name
dart test --name "happy path"
```

---

## ApiResult\<T\> assertions

```dart
expect(result.isSuccess, true);
expect(result.statusCode, 200);
expect(result.data, {'users': []});
expect(result.errorMessage, contains('invalid'));
```
