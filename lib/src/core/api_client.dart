import 'dart:convert';

import '../auth/auth_interceptor.dart';
import '../auth/token_storage.dart';
import '../http/default_http_adapter.dart';
import '../http/http_adapter.dart';
import '../interceptors/interceptor.dart';
import '../interceptors/interceptor_chain.dart';
import '../response/response_handler.dart';
import '../response/response_handler_interface.dart';
import 'api_exception.dart';
import 'api_response.dart';
import 'api_result.dart';
import 'form_data.dart';
import 'query.dart';
import 'request_options.dart';
import 'response_type.dart';

/// Configuration for [ApiClient].
class ApiClientConfig {
  ApiClientConfig({
    required this.baseUrl,
    this.tokenStorage,
    this.getAccessToken,
    this.refreshToken,
    this.extraHeaders = const {},
    this.connectTimeout = const Duration(seconds: 30),
    this.authScheme = 'Bearer',
    this.responseHandler,
    this.interceptors = const [],
    this.adapter,
  });

  final String baseUrl;
  final TokenStorage? tokenStorage;
  final Future<String?> Function()? getAccessToken;
  final Future<bool> Function()? refreshToken;
  final Map<String, String> extraHeaders;
  final Duration connectTimeout;
  final String authScheme;
  final ResponseHandlerInterface? responseHandler;
  final List<Interceptor> interceptors;
  final HttpAdapter? adapter;

  factory ApiClientConfig.withToken({
    required String baseUrl,
    required Future<String?> Function() getAccessToken,
    Future<bool> Function()? refreshToken,
    Map<String, String> extraHeaders = const {},
    Duration connectTimeout = const Duration(seconds: 30),
    String authScheme = 'Bearer',
    List<Interceptor> interceptors = const [],
  }) => ApiClientConfig(
    baseUrl: baseUrl,
    getAccessToken: getAccessToken,
    refreshToken: refreshToken,
    extraHeaders: extraHeaders,
    connectTimeout: connectTimeout,
    authScheme: authScheme,
    interceptors: interceptors,
  );

  factory ApiClientConfig.withStorage({
    required String baseUrl,
    required TokenStorage tokenStorage,
    Future<bool> Function()? refreshToken,
    Map<String, String> extraHeaders = const {},
    Duration connectTimeout = const Duration(seconds: 30),
    String authScheme = 'Bearer',
    List<Interceptor> interceptors = const [],
  }) => ApiClientConfig(
    baseUrl: baseUrl,
    tokenStorage: tokenStorage,
    refreshToken: refreshToken,
    extraHeaders: extraHeaders,
    connectTimeout: connectTimeout,
    authScheme: authScheme,
    interceptors: interceptors,
  );

  factory ApiClientConfig.test({
    required String baseUrl,
    required HttpAdapter adapter,
    List<Interceptor> interceptors = const [],
  }) => ApiClientConfig(
    baseUrl: baseUrl,
    adapter: adapter,
    interceptors: interceptors,
  );
}

/// Public API of an HTTP client.
abstract class ApiClientInterface {
  Future<CustomApiResponse<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<CustomApiResponse<T>> post<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<CustomApiResponse<T>> put<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<CustomApiResponse<T>> patch<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<CustomApiResponse<T>> delete<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });
}

/// HTTP API client with pluggable transport, interceptors, retries, caching,
/// dedup, refresh-queue auth, and spec-driven mocks.
class ApiClient implements ApiClientInterface {
  ApiClient(ApiClientConfig config)
    : _config = config,
      _adapter = config.adapter ?? DefaultHttpAdapter(),
      _responseHandler = config.responseHandler ?? const ResponseHandler(),
      _chain = InterceptorChain([
        ..._buildAutoAuthInterceptor(config),
        ...config.interceptors,
      ]);

  final ApiClientConfig _config;
  final HttpAdapter _adapter;
  final ResponseHandlerInterface _responseHandler;
  final InterceptorChain _chain;

  static List<Interceptor> _buildAutoAuthInterceptor(ApiClientConfig c) {
    if (c.tokenStorage != null) {
      return [
        AuthInterceptor(
          storage: c.tokenStorage!,
          refresh: c.refreshToken,
          authScheme: c.authScheme,
        ),
      ];
    }
    if (c.getAccessToken != null) {
      return [
        AuthInterceptor(
          storage: _CallbackTokenStorage(c.getAccessToken!),
          refresh: c.refreshToken,
          authScheme: c.authScheme,
        ),
      ];
    }
    return const [];
  }

  HttpAdapter get adapter => _adapter;

  /// Returns a typed result. Recommended for new code.
  Future<ApiResult<T>> request<T>(
    String method,
    String endpoint, {
    dynamic data,
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) async {
    try {
      final res = await _send(
        method: method,
        endpoint: endpoint,
        data: data,
        includeToken: includeToken,
        isMultipart: isMultipart,
        options: options,
      );
      final responseType = options?.responseType ?? ResponseType.json;
      final parsed = _decode<T>(res, responseType, decoder);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return Success<T>(
          parsed as T,
          statusCode: res.statusCode,
          headers: res.headers,
        );
      }
      final msg =
          _responseHandler.handleResponse(res) ?? 'HTTP ${res.statusCode}';
      return Failure<T>(
        HttpError(
          msg,
          statusCode: res.statusCode,
          body: parsed,
          headers: res.headers,
        ),
        statusCode: res.statusCode,
      );
    } on ApiException catch (e) {
      return Failure<T>(e);
    } catch (e, st) {
      return Failure<T>(UnknownError(e.toString(), cause: e, stackTrace: st));
    }
  }

  @override
  Future<CustomApiResponse<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _makeRequest<T>(
    'GET',
    endpoint,
    includeToken: includeToken,
    options: options,
    decoder: decoder,
  );

  @override
  Future<CustomApiResponse<T>> post<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _makeRequest<T>(
    'POST',
    endpoint,
    data: data,
    includeToken: includeToken,
    isMultipart: isMultipart,
    options: options,
    decoder: decoder,
  );

  @override
  Future<CustomApiResponse<T>> put<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _makeRequest<T>(
    'PUT',
    endpoint,
    data: data,
    includeToken: includeToken,
    isMultipart: isMultipart,
    options: options,
    decoder: decoder,
  );

  @override
  Future<CustomApiResponse<T>> patch<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _makeRequest<T>(
    'PATCH',
    endpoint,
    data: data,
    includeToken: includeToken,
    isMultipart: isMultipart,
    options: options,
    decoder: decoder,
  );

  @override
  Future<CustomApiResponse<T>> delete<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) => _makeRequest<T>(
    'DELETE',
    endpoint,
    includeToken: includeToken,
    options: options,
    decoder: decoder,
  );

  Future<CustomApiResponse<T>> _makeRequest<T>(
    String method,
    String endpoint, {
    dynamic data,
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) async {
    try {
      final res = await _send(
        method: method,
        endpoint: endpoint,
        data: data,
        includeToken: includeToken,
        isMultipart: isMultipart,
        options: options,
      );
      final responseType = options?.responseType ?? ResponseType.json;
      final parsed = _decode<T>(res, responseType, decoder);
      final isSuccess = res.statusCode >= 200 && res.statusCode < 300;
      return CustomApiResponse<T>(
        statusCode: res.statusCode,
        headers: res.headers,
        data: parsed as T?,
        isSuccess: isSuccess,
        errorMessage: isSuccess ? null : _responseHandler.handleResponse(res),
        rawBody: res.bodyBytes,
      );
    } on CancelError catch (e) {
      return CustomApiResponse<T>(
        statusCode: 0,
        headers: const {},
        data: null,
        isSuccess: false,
        errorMessage: e.message,
      );
    } on ApiException catch (e) {
      return CustomApiResponse<T>(
        statusCode: 0,
        headers: const {},
        data: null,
        isSuccess: false,
        errorMessage: e.message,
      );
    } catch (e) {
      return CustomApiResponse<T>(
        statusCode: 0,
        headers: const {},
        data: null,
        isSuccess: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<AdapterResponse> _send({
    required String method,
    required String endpoint,
    dynamic data,
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  }) async {
    final effectiveIncludeToken = options?.includeToken ?? includeToken;
    final effectiveTimeout = options?.timeout ?? _config.connectTimeout;
    final effectiveBaseUrl = options?.baseUrlOverride ?? _config.baseUrl;
    final mergedOptions = (options ?? const RequestOptions()).copyWith(
      includeToken: effectiveIncludeToken,
      timeout: effectiveTimeout,
      baseUrlOverride: effectiveBaseUrl,
    );

    final headers = <String, String>{
      'Accept': 'application/json',
      'Accept-Language': 'en',
      if (!isMultipart) 'Content-Type': 'application/json',
      ..._config.extraHeaders,
      ...mergedOptions.extraHeaders,
      ...?mergedOptions.headers,
    };

    final req = InterceptedRequest(
      method: method.toUpperCase(),
      endpoint: endpoint,
      headers: headers,
      options: mergedOptions,
      data: data,
      isMultipart: isMultipart,
    );

    return _chain.run(request: req, transport: (r) => _transport(r));
  }

  Future<AdapterResponse> _transport(InterceptedRequest req) async {
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? _config.baseUrl,
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    );
    FormData? formData;
    Object? body;
    if (req.isMultipart) {
      if (req.data is FormData) {
        formData = req.data as FormData;
      } else if (req.data is Map<String, dynamic>) {
        formData = FormData.fromMap(req.data as Map<String, dynamic>);
      }
    } else if (req.data != null) {
      body = encodeBody(req.data);
    }
    return _adapter.send(
      AdapterRequest(
        method: req.method,
        url: url,
        headers: req.headers,
        body: body,
        formData: formData,
        isMultipart: req.isMultipart,
        timeout: req.options.timeout ?? _config.connectTimeout,
        cancelToken: req.options.cancelToken,
        onSendProgress: req.options.onSendProgress,
        onReceiveProgress: req.options.onReceiveProgress,
      ),
    );
  }

  Object? _decode<T>(
    AdapterResponse res,
    ResponseType type,
    T Function(Object json)? decoder,
  ) {
    switch (type) {
      case ResponseType.bytes:
        return res.bodyBytes;
      case ResponseType.plainText:
        return utf8.decode(res.bodyBytes);
      case ResponseType.stream:
        return res.bodyBytes;
      case ResponseType.json:
        if (res.bodyBytes.isEmpty) return null;
        try {
          final raw = utf8.decode(res.bodyBytes);
          if (raw.trim().isEmpty) return null;
          if (_responseHandler.isHtmlOrTextResponse(raw)) return null;
          final parsed = jsonDecode(raw);
          if (decoder != null && parsed != null) {
            return decoder(parsed as Object);
          }
          return parsed;
        } catch (_) {
          return null;
        }
    }
  }

  void close() => _adapter.close();
}

class _CallbackTokenStorage implements TokenStorage {
  _CallbackTokenStorage(this._cb);
  final Future<String?> Function() _cb;

  @override
  Future<String?> getAccessToken() => _cb();
  @override
  Future<void> setAccessToken(String? token) async {}
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<void> clear() async {}
}
