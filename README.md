# Flutter API Client

A reusable, extensible HTTP API client for Flutter/Dart apps. Supports custom storage, interceptors, per-request options, and works with SharedPreferences, GetIt, SecureStorage, and more.

## Features

- **Standard methods**: GET, POST, PUT, PATCH, DELETE
- **Custom token storage**: Implement `TokenStorage` for any storage (SharedPreferences, SecureStorage, GetIt, Hive)
- **Callback-based auth**: Use `getAccessToken` for simple setups
- **Per-request options**: Custom headers, timeout, base URL override per request
- **Request/response interceptors**: Modify requests before send and responses after receive
- **Custom response handler**: Implement `ResponseHandlerInterface` for your own error parsing
- **Configurable auth**: Bearer, Basic, or custom scheme
- **Multipart uploads**: File upload support

## Installation

```yaml
dependencies:
  flutter_api_client:
    path: ../flutter_api_client  # or from pub.dev when published
  http: ^1.2.2
```

## Usage

### Basic (no auth)

```dart
final config = ApiClientConfig(
  baseUrl: 'https://api.example.com/api/v1',
  getAccessToken: () async => null,
);
final apiClient = ApiClient(config);
```

### With SharedPreferences

```dart
final prefs = await SharedPreferences.getInstance();

final config = ApiClientConfig(
  baseUrl: 'https://api.example.com/api/v1',
  getAccessToken: () async => prefs.getString('access_token'),
  refreshToken: () async {
    final refresh = prefs.getString('refresh_token');
    if (refresh == null) return false;
    // Implement your refresh logic
    return false;
  },
  extraHeaders: {'X-App-Version': '1.0.0'},
);
final apiClient = ApiClient(config);
```

### With custom TokenStorage

```dart
class MyTokenStorage implements TokenStorage {
  MyTokenStorage(this._prefs);
  final SharedPreferences _prefs;

  @override
  Future<String?> getAccessToken() => Future.value(_prefs.getString('access_token'));

  @override
  Future<void> setAccessToken(String? token) async {
    if (token != null) {
      await _prefs.setString('access_token', token);
    } else {
      await _prefs.remove('access_token');
    }
  }
}

final config = ApiClientConfig.withStorage(
  baseUrl: 'https://api.example.com/api/v1',
  tokenStorage: MyTokenStorage(prefs),
);
final apiClient = ApiClient(config);
```

### Per-request options

```dart
// Custom headers
await apiClient.get('users', options: RequestOptions(
  headers: {'X-Custom': 'value'},
  extraHeaders: {'X-Request-ID': 'req-123'},
));

// Different timeout
await apiClient.get('slow-endpoint', options: RequestOptions(
  timeout: Duration(seconds: 60),
));

// No auth for public endpoint
await apiClient.get('public/data', includeToken: false);
// or
await apiClient.get('public/data', options: RequestOptions(includeToken: false));

// Different base URL
await apiClient.get('assets', options: RequestOptions(
  baseUrlOverride: 'https://cdn.example.com',
));
```

### Interceptors

```dart
class LoggingInterceptor extends RequestInterceptor {
  @override
  Future<InterceptedRequest> onRequest(
    String method,
    String endpoint, {
    dynamic data,
    Map<String, String>? headers,
    bool isMultipart = false,
  }) async {
    print('$method $endpoint');
    return InterceptedRequest(
      method: method,
      endpoint: endpoint,
      data: data,
      headers: headers,
      isMultipart: isMultipart,
    );
  }
}

final config = ApiClientConfig(
  baseUrl: 'https://api.example.com',
  getAccessToken: () async => null,
  requestInterceptor: LoggingInterceptor(),
);
```

### Custom response handler

```dart
class MyResponseHandler implements ResponseHandlerInterface {
  @override
  String? handleResponse(http.Response res) {
    // Your custom error parsing
    return null;
  }

  @override
  bool isHtmlOrTextResponse(String body) => body.trim().startsWith('<');
}

final config = ApiClientConfig(
  baseUrl: 'https://api.example.com',
  getAccessToken: () async => null,
  responseHandler: MyResponseHandler(),
);
```

### API calls

```dart
// GET
final response = await apiClient.get('users/profile');
if (response.isSuccess) {
  final data = response.data as Map<String, dynamic>;
  print(data['name']);
} else {
  print(response.errorMessage);
}

// POST
await apiClient.post('auth/login', {'email': 'x@y.com', 'password': 'secret'});

// Multipart
final multipartData = {'file': await http.MultipartFile.fromPath('file', filePath)};
await apiClient.post('files/upload', multipartData, isMultipart: true);

// PUT / PATCH / DELETE
await apiClient.put('users/1', {'name': 'New Name'});
await apiClient.patch('users/1', {'email': 'new@email.com'});
await apiClient.delete('users/1');
```

## Extending and modifying

- **Extend ApiClient**: Create a subclass and override `_makeRequest` or individual methods.
- **Custom storage**: Implement `TokenStorage` for any backend.
- **Custom errors**: Implement `ResponseHandlerInterface`.
- **Request/response hooks**: Use `RequestInterceptor` and `ResponseInterceptor`.
