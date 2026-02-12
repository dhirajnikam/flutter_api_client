import 'dart:convert';

import 'package:http/http.dart' as http;

import 'custom_api_response.dart';
import 'http_service.dart';
import 'interceptors.dart';
import 'request_options.dart';
import 'response_handler.dart';
import 'response_handler_interface.dart';
import 'token_storage.dart';

/// Configuration for [ApiClient].
///
/// Provide either [getAccessToken] (callback) or [tokenStorage] for auth.
class ApiClientConfig {
  ApiClientConfig({
    required this.baseUrl,
    this.getAccessToken,
    this.tokenStorage,
    this.refreshToken,
    this.extraHeaders = const {},
    this.connectTimeout = const Duration(seconds: 30),
    this.authScheme = 'Bearer',
    this.responseHandler,
    this.requestInterceptor,
    this.responseInterceptor,
  }) : assert(
         getAccessToken != null || tokenStorage != null,
         'Provide getAccessToken or tokenStorage',
       );

  final String baseUrl;
  final Future<String?> Function()? getAccessToken;
  final TokenStorage? tokenStorage;
  final Future<bool> Function()? refreshToken;
  final Map<String, String> extraHeaders;
  final Duration connectTimeout;
  final String authScheme;
  final ResponseHandlerInterface? responseHandler;
  final RequestInterceptor? requestInterceptor;
  final ResponseInterceptor? responseInterceptor;

  /// Config with callback-based token (no custom storage).
  factory ApiClientConfig.withToken({
    required String baseUrl,
    required Future<String?> Function() getAccessToken,
    Future<bool> Function()? refreshToken,
    Map<String, String> extraHeaders = const {},
    Duration connectTimeout = const Duration(seconds: 30),
    String authScheme = 'Bearer',
  }) => ApiClientConfig(
    baseUrl: baseUrl,
    getAccessToken: getAccessToken,
    refreshToken: refreshToken,
    extraHeaders: extraHeaders,
    connectTimeout: connectTimeout,
    authScheme: authScheme,
  );

  /// Config with custom [TokenStorage].
  factory ApiClientConfig.withStorage({
    required String baseUrl,
    required TokenStorage tokenStorage,
    Future<bool> Function()? refreshToken,
    Map<String, String> extraHeaders = const {},
    Duration connectTimeout = const Duration(seconds: 30),
    String authScheme = 'Bearer',
  }) => ApiClientConfig(
    baseUrl: baseUrl,
    tokenStorage: tokenStorage,
    refreshToken: refreshToken,
    extraHeaders: extraHeaders,
    connectTimeout: connectTimeout,
    authScheme: authScheme,
  );
}

/// Interface for HTTP API client operations.
abstract class ApiClientInterface {
  /// Sends a GET request to [endpoint].
  Future<CustomApiResponse> get(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
  });

  /// Sends a POST request to [endpoint] with [data].
  Future<CustomApiResponse> post(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  });

  /// Sends a PUT request to [endpoint] with [data].
  Future<CustomApiResponse> put(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  });

  /// Sends a PATCH request to [endpoint] with [data].
  Future<CustomApiResponse> patch(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  });

  /// Sends a DELETE request to [endpoint].
  Future<CustomApiResponse> delete(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
  });
}

/// HTTP API client with auth, interceptors, and configurable storage.
///
/// Use [ApiClientConfig] to configure base URL, token retrieval, and options.
class ApiClient implements ApiClientInterface {
  /// Creates an [ApiClient] with the given [config].
  ApiClient(ApiClientConfig config)
    : _config = config,
      _httpService = HttpService(config.baseUrl),
      _responseHandler = config.responseHandler ?? ResponseHandler();

  final ApiClientConfig _config;
  final HttpService _httpService;
  final ResponseHandlerInterface _responseHandler;
  static const List<int> _successStatusCodes = [200, 201, 204];

  @override
  Future<CustomApiResponse> get(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
  }) => _makeRequest(
    'GET',
    endpoint,
    includeToken: includeToken,
    options: options,
  );

  @override
  Future<CustomApiResponse> post(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  }) => _makeRequest(
    'POST',
    endpoint,
    data: data,
    includeToken: includeToken,
    isMultipart: isMultipart,
    options: options,
  );

  @override
  Future<CustomApiResponse> put(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  }) => _makeRequest(
    'PUT',
    endpoint,
    data: data,
    includeToken: includeToken,
    isMultipart: isMultipart,
    options: options,
  );

  @override
  Future<CustomApiResponse> patch(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  }) => _makeRequest(
    'PATCH',
    endpoint,
    data: data,
    includeToken: includeToken,
    isMultipart: isMultipart,
    options: options,
  );

  @override
  Future<CustomApiResponse> delete(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
  }) => _makeRequest(
    'DELETE',
    endpoint,
    includeToken: includeToken,
    options: options,
  );

  Future<CustomApiResponse> _makeRequest(
    String method,
    String endpoint, {
    dynamic data,
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  }) async {
    final effectiveIncludeToken = options?.includeToken ?? includeToken;
    final effectiveTimeout = options?.timeout ?? _config.connectTimeout;

    var requestData = data;
    var headers = await _buildHeaders(effectiveIncludeToken, isMultipart);

    if (options != null) {
      if (options.headers != null) {
        headers.addAll(options.headers!);
      }
      headers.addAll(options.extraHeaders);
    }

    if (_config.requestInterceptor != null) {
      final intercepted = await _config.requestInterceptor!.onRequest(
        method,
        endpoint,
        data: requestData,
        headers: headers,
        isMultipart: isMultipart,
      );
      requestData = intercepted.data;
      headers = intercepted.headers ?? headers;
    }

    final cancellable = _httpService.sendRequest(
      method,
      endpoint,
      data: requestData,
      headers: headers,
      isMultipart: isMultipart,
      timeout: effectiveTimeout,
      baseUrlOverride: options?.baseUrlOverride,
    );

    try {
      final httpResponse = await cancellable.future;
      var response = _handleResponse(httpResponse);

      if (_config.responseInterceptor != null) {
        final modified = await _config.responseInterceptor!.onResponse(
          httpResponse,
          response,
        );
        if (modified != null) {
          response = modified;
        }
      }

      return response;
    } catch (e) {
      return CustomApiResponse(
        statusCode: 0,
        headers: {},
        data: null,
        isSuccess: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<Map<String, String>> _buildHeaders(
    bool includeToken,
    bool isMultipart,
  ) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'en',
      ..._config.extraHeaders,
    };

    if (includeToken) {
      final token = await _getAccessToken();
      if (token != null && token.isNotEmpty) {
        final scheme = _config.authScheme;
        headers['Authorization'] = scheme.isEmpty ? token : '$scheme $token';
      }
    }

    if (isMultipart && headers.containsKey('Content-Type')) {
      headers.remove('Content-Type');
    }
    return headers;
  }

  Future<String?> _getAccessToken() async {
    if (_config.tokenStorage != null) {
      return _config.tokenStorage!.getAccessToken();
    }
    return _config.getAccessToken!();
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
          errorMessage:
              'The server returned an invalid response. Please try again later.',
        );
      }
      final parsedData = jsonDecode(responseBody);
      final isSuccess = _successStatusCodes.contains(response.statusCode);
      String? errorMessage;
      if (!isSuccess) {
        errorMessage = _responseHandler.handleResponse(response);
      }
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
