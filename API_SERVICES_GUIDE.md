# API Services Guide

> **Copy this file to another project.** Use the code below to implement API call services in any Flutter/Dart app.

---

## 1. Dependencies (pubspec.yaml)

```yaml
dependencies:
  http: ^1.2.2
```

---

## 2. Project Structure

Create these files in your project (e.g. `lib/core/api/`):

```
lib/core/api/
├── custom_api_response.dart
├── response_handler.dart
├── http_service.dart
└── api_client.dart
```

---

## 3. Code to Copy

### 3.1 custom_api_response.dart

```dart
/// Standard API response wrapper for consistent handling across calls.
class CustomApiResponse {
  CustomApiResponse({
    required this.statusCode,
    required this.headers,
    required this.data,
    required this.isSuccess,
    this.errorMessage,
  });

  final dynamic data;
  final String? errorMessage;
  final Map<String, String> headers;
  final bool isSuccess;
  final int statusCode;
}
```

### 3.2 response_handler.dart

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

class ResponseHandler {
  String? handleResponse(http.Response res) {
    try {
      final responseBody = utf8.decode(res.bodyBytes);

      if (responseBody.trim().isEmpty) {
        if (res.statusCode >= 200 && res.statusCode < 300) return null;
        return 'Server returned an empty response';
      }

      if (isHtmlOrTextResponse(responseBody)) {
        return 'The server returned an invalid response. Please try again later.';
      }

      try {
        final Map<String, dynamic> response = jsonDecode(responseBody);
        if (res.statusCode >= 200 && res.statusCode < 300) return null;
        final String errorMessage = getErrorMessage(response['message']);
        return errorMessage.isNotEmpty ? errorMessage : 'An unexpected error occurred.';
      } on FormatException {
        if (res.statusCode >= 200 && res.statusCode < 300) return null;
        return 'Failed to parse the response. Please try again later.';
      }
    } catch (e) {
      return 'Failed to process the response. Please check your connection and try again.';
    }
  }

  String getErrorMessage(dynamic error) {
    if (error == null) return 'An unknown error occurred.';
    if (error is String) return error.isNotEmpty ? error : 'An unknown error occurred.';
    if (error is List) return error.join(', ');
    if (error is Map<String, dynamic>) {
      String errorMessage = '';
      error.forEach((key, value) {
        if (value is List) errorMessage += '$key: ${value.join(', ')}\n';
        else if (value is String) errorMessage += '$value\n';
        else if (value is Map<String, dynamic>) errorMessage += '$key: ${value.toString()}\n';
      });
      return errorMessage.trim().isNotEmpty ? errorMessage.trim() : 'An unexpected error occurred.';
    }
    return error.toString();
  }

  bool isHtmlOrTextResponse(String responseBody) {
    final t = responseBody.trim();
    if (t.startsWith('<!DOCTYPE html>') || t.startsWith('<html') ||
        (t.contains('<head>') && t.contains('<body>'))) return true;
    if (t.isEmpty) return false;
    if (t.length < 5 && !t.startsWith('{') && !t.startsWith('[')) return true;
    return false;
  }
}
```

### 3.3 http_service.dart

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

class CancellableRequest<T> {
  CancellableRequest(this._client, this.future);

  final http.Client _client;
  final Future<T> future;
  bool _isCancelled = false;

  void cancel() {
    if (!_isCancelled) {
      _client.close();
      _isCancelled = true;
    }
  }

  bool get isCancelled => _isCancelled;
}

class HttpService {
  HttpService(this.baseUrl);

  final String baseUrl;
  static final http.Client _client = http.Client();
  static const Duration requestTimeout = Duration(seconds: 30);

  CancellableRequest<http.Response> sendRequest(
    String method,
    String endpoint, {
    dynamic data,
    Map<String, String>? headers,
    bool isMultipart = false,
    Duration? timeout,
  }) {
    final effectiveTimeout = timeout ?? requestTimeout;
    final url = Uri.parse('$baseUrl/$endpoint');
    bool isCancelled = false;
    Future<http.Response> future;

    if (isMultipart) {
      future = sendMultipartRequest(method, url, data: data, headers: headers, client: _client)
          .timeout(effectiveTimeout);
    } else {
      switch (method.toUpperCase()) {
        case 'GET':
          future = _client.get(url, headers: headers).timeout(effectiveTimeout);
          break;
        case 'POST':
          future = _client.post(url, headers: headers, body: jsonEncode(data)).timeout(effectiveTimeout);
          break;
        case 'PATCH':
          future = _client.patch(url, headers: headers, body: jsonEncode(data)).timeout(effectiveTimeout);
          break;
        case 'PUT':
          future = _client.put(url, headers: headers, body: jsonEncode(data)).timeout(effectiveTimeout);
          break;
        case 'DELETE':
          future = _client.delete(url, headers: headers).timeout(effectiveTimeout);
          break;
        default:
          throw UnsupportedError('HTTP method $method not supported');
      }
    }

    future = future.whenComplete(() {});
    return _CancellableRequestWithCallback(_client, future, () => isCancelled = true);
  }

  Future<http.Response> sendMultipartRequest(
    String method,
    Uri url, {
    dynamic data,
    Map<String, String>? headers,
    http.Client? client,
  }) async {
    final effectiveClient = client ?? http.Client();
    final shouldCloseClient = client == null;
    try {
      var request = http.MultipartRequest(method, url);
      if (headers != null) request.headers.addAll(headers);
      if (data != null) {
        data.forEach((key, value) {
          if (value is List<http.MultipartFile>) request.files.addAll(value);
          else if (value is http.MultipartFile) request.files.add(value);
          else request.fields[key] = value.toString();
        });
      }
      var streamedResponse = await effectiveClient.send(request);
      return await http.Response.fromStream(streamedResponse);
    } finally {
      if (shouldCloseClient) effectiveClient.close();
    }
  }
}

class _CancellableRequestWithCallback<T> extends CancellableRequest<T> {
  _CancellableRequestWithCallback(super.client, super.future, this.onCancel);
  final void Function() onCancel;

  @override
  void cancel() {
    if (!_isCancelled) {
      onCancel();
      super.cancel();
    }
  }
}
```

### 3.4 api_client.dart

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'custom_api_response.dart';
import 'http_service.dart';
import 'response_handler.dart';

class ApiClientConfig {
  ApiClientConfig({
    required this.baseUrl,
    required this.getAccessToken,
    this.refreshToken,
    this.extraHeaders = const {},
  });

  final String baseUrl;
  final Future<String?> Function() getAccessToken;
  final Future<bool> Function()? refreshToken;
  final Map<String, String> extraHeaders;
}

abstract class ApiClientInterface {
  Future<CustomApiResponse> get(String endpoint, {bool includeToken = true});
  Future<CustomApiResponse> post(String endpoint, dynamic data, {bool includeToken = true, bool isMultipart = false});
  Future<CustomApiResponse> put(String endpoint, dynamic data, {bool includeToken = true, bool isMultipart = false});
  Future<CustomApiResponse> patch(String endpoint, dynamic data, {bool includeToken = true, bool isMultipart = false});
  Future<CustomApiResponse> delete(String endpoint, {bool includeToken = true});
}

class ApiClient implements ApiClientInterface {
  ApiClient(ApiClientConfig config)
      : _config = config,
        _httpService = HttpService(config.baseUrl),
        _responseHandler = ResponseHandler();

  final ApiClientConfig _config;
  final HttpService _httpService;
  final ResponseHandler _responseHandler;
  static const List<int> _successStatusCodes = [200, 201, 204];

  @override
  Future<CustomApiResponse> get(String endpoint, {bool includeToken = true}) =>
      _makeRequest('GET', endpoint, includeToken: includeToken);

  @override
  Future<CustomApiResponse> post(String endpoint, dynamic data, {bool includeToken = true, bool isMultipart = false}) =>
      _makeRequest('POST', endpoint, data: data, includeToken: includeToken, isMultipart: isMultipart);

  @override
  Future<CustomApiResponse> put(String endpoint, dynamic data, {bool includeToken = true, bool isMultipart = false}) =>
      _makeRequest('PUT', endpoint, data: data, includeToken: includeToken, isMultipart: isMultipart);

  @override
  Future<CustomApiResponse> patch(String endpoint, dynamic data, {bool includeToken = true, bool isMultipart = false}) =>
      _makeRequest('PATCH', endpoint, data: data, includeToken: includeToken, isMultipart: isMultipart);

  @override
  Future<CustomApiResponse> delete(String endpoint, {bool includeToken = true}) =>
      _makeRequest('DELETE', endpoint, includeToken: includeToken);

  Future<CustomApiResponse> _makeRequest(
    String method,
    String endpoint, {
    dynamic data,
    bool includeToken = true,
    bool isMultipart = false,
  }) async {
    final headers = await _buildHeaders(includeToken, isMultipart);
    final cancellable = _httpService.sendRequest(method, endpoint, data: data, headers: headers, isMultipart: isMultipart);
    try {
      final httpResponse = await cancellable.future;
      return _handleResponse(httpResponse);
    } catch (e) {
      return CustomApiResponse(statusCode: 0, headers: {}, data: null, isSuccess: false, errorMessage: e.toString());
    }
  }

  Future<Map<String, String>> _buildHeaders(bool includeToken, bool isMultipart) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'en',
      ..._config.extraHeaders,
    };
    if (includeToken) {
      final token = await _config.getAccessToken();
      if (token != null && token.isNotEmpty) headers['Authorization'] = 'Bearer $token';
    }
    if (isMultipart && headers.containsKey('Content-Type')) headers.remove('Content-Type');
    return headers;
  }

  CustomApiResponse _handleResponse(http.Response response) {
    try {
      final responseBody = utf8.decode(response.bodyBytes);
      if (responseBody.trim().isEmpty) {
        final isSuccess = _successStatusCodes.contains(response.statusCode);
        return CustomApiResponse(
          statusCode: response.statusCode,
          headers: response.headers,
          data: null,
          isSuccess: isSuccess,
          errorMessage: isSuccess ? null : 'Server returned an empty response',
        );
      }
      if (_responseHandler.isHtmlOrTextResponse(responseBody)) {
        return CustomApiResponse(
          statusCode: response.statusCode,
          headers: response.headers,
          data: null,
          isSuccess: false,
          errorMessage: 'The server returned an invalid response. Please try again later.',
        );
      }
      final parsedData = jsonDecode(responseBody);
      final isSuccess = _successStatusCodes.contains(response.statusCode);
      String? errorMessage;
      if (!isSuccess) errorMessage = _responseHandler.handleResponse(response);
      return CustomApiResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        data: parsedData,
        isSuccess: isSuccess,
        errorMessage: errorMessage,
      );
    } on FormatException catch (e) {
      final isSuccess = _successStatusCodes.contains(response.statusCode);
      return CustomApiResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        data: null,
        isSuccess: isSuccess,
        errorMessage: isSuccess ? null : 'Failed to parse JSON: $e',
      );
    } catch (e) {
      return CustomApiResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        data: null,
        isSuccess: false,
        errorMessage: 'An unexpected error occurred: $e',
      );
    }
  }
}
```

---

## 4. Setup (in your app)

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

### With GetIt

```dart
final apiConfig = ApiClientConfig(
  baseUrl: 'https://api.example.com/api/v1',
  getAccessToken: () async => locator<SharedPreferenceManager>().getAccessToken(),
  refreshToken: () async => locator<AuthService>().refreshToken(),
);
locator.registerLazySingleton<ApiClient>(() => ApiClient(apiConfig));
```

---

## 5. Usage Examples

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
final response = await apiClient.post('auth/login', {'email': 'x@y.com', 'password': 'secret'});

// Multipart
final multipartData = {'file': await http.MultipartFile.fromPath('file', filePath)};
final response = await apiClient.post('files/upload', multipartData, isMultipart: true);

// PUT / PATCH / DELETE
await apiClient.put('users/1', {'name': 'New Name'});
await apiClient.patch('users/1', {'email': 'new@email.com'});
await apiClient.delete('users/1');

// Public endpoint (no token)
await apiClient.get('public/data', includeToken: false);
```

---

## 6. Cursor Commands (Copy to New Project)

Ask Cursor:

1. **"Create the API service files from API_SERVICES_GUIDE.md section 3"**
2. **"Set up ApiClient with ApiClientConfig using SharedPreferences for token"**
3. **"Register ApiClient in GetIt initDependencies"**

---

*Generated from FSM OMS Mobile (dpr) - Copy to any Flutter project.*
