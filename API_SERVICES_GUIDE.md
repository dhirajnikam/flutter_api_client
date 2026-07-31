# API Services Guide

> Copy this guide to any Flutter/Dart project. It shows how to define, mock, and test APIs using `flutter_api_client`.

---

## 1. Dependencies (pubspec.yaml)

```yaml
dependencies:
  flutter_api_client: ^1.4.0

dev_dependencies:
  build_runner: ^2.4.0
```

---

## 2. Project structure

```
lib/core/api/
├── my_api.dart           # @ApiSpecEntry() definition — you write this
├── my_api.g.dart         # generated — do not edit
├── my_api.test.g.dart    # generated test scaffold — do not edit
└── api_service.dart      # your service layer
```

---

## 3. Define your spec

```dart
// lib/core/api/my_api.dart
import 'package:flutter_api_client/flutter_api_client.dart';
part 'my_api.g.dart';

@ApiSpecEntry()
final myApiSpec = ApiSpec(
  title: 'My App API',
  version: '1.0.0',
  baseUrl: 'https://api.example.com/v1',
)..group('Users', (g) {
    g.endpoint(
      'GET /users',
      summary: 'List users',
      responses: [ResponseExample.ok({'users': [], 'total': 0})],
    );
    g.endpoint(
      'POST /users',
      summary: 'Create user',
      request: RequestExample(
        body: {'name': 'Alice', 'email': 'alice@example.com'},
        schema: Schema.object({
          'name': Schema.string(required: true),
          'email': Schema.string(format: 'email', required: true),
        }),
      ),
      responses: [
        ResponseExample.created({'id': 1, 'name': 'Alice'}),
        ResponseExample.error(422, {'message': 'validation error'}),
      ],
    );
  });
```

```bash
dart run build_runner build
```

---

## 4. Create your ApiClient

```dart
// lib/core/api/api_service.dart
import 'package:flutter_api_client/flutter_api_client.dart';

final apiClient = ApiClient(
  ApiClientConfig(
    baseUrl: 'https://api.example.com/v1',
    tokenStorage: MemoryTokenStorage(accessToken: 'your-jwt-here'),
    interceptors: [
      RetryInterceptor(),
      CacheInterceptor(store: MemoryCacheStore()),
      PrettyLogger(),
    ],
  ),
);
```

---

## 5. Make requests — ApiResult\<T\>

All methods return `ApiResult<T>`, a sealed class with two subtypes: `Success<T>` and `Failure<T>`.

```dart
// Pattern A — isSuccess check
final result = await apiClient.get<Map<String, dynamic>>('users');
if (result.isSuccess) {
  final users = result.data;
} else {
  print(result.errorMessage);
}

// Pattern B — when()
final created = await apiClient.post<Map<String, dynamic>>(
  'users',
  {'name': 'Alice', 'email': 'alice@example.com'},
);
created.when(
  success: (data) => print('Created: $data'),
  failure: (error) => print('Error: ${error.message}'),
);

// Pattern C — switch (Dart 3)
switch (created) {
  case Success(:final data):
    print(data);
  case Failure(:final error):
    print(error.message);
}
```

---

## 6. Testing

```bash
# Generate a full test suite from your spec:
dart run flutter_api_client:gen --only tests
# Writes: test/api_spec_test.dart

dart test --concurrency=8
```

Or use `SpecMockAdapter` directly in your own tests:

```dart
final client = ApiClient(ApiClientConfig.test(
  baseUrl: 'https://api.example.com/v1',
  adapter: SpecMockAdapter(myApiSpec),
));
final result = await client.get<Map<String, dynamic>>('users');
expect(result.isSuccess, true);
```

See [TESTING.md](TESTING.md) for a full cheat-sheet.
