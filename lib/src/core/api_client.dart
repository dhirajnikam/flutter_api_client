import 'dart:convert';

import '../auth/auth_interceptor.dart';
import '../auth/token_storage.dart';
import '../http/default_http_adapter.dart';
import '../http/http_adapter.dart';
import '../interceptors/interceptor.dart';
import '../interceptors/interceptor_chain.dart';
import '../interceptors/request_identity.dart';
import '../response/response_handler.dart';
import '../response/response_handler_interface.dart';
import 'api_exception.dart';
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
    this.maxRequestBodyBytes,
    this.maxResponseBodyBytes,
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
  final int? maxRequestBodyBytes;
  final int? maxResponseBodyBytes;
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
    int? maxRequestBodyBytes,
    int? maxResponseBodyBytes,
    List<Interceptor> interceptors = const [],
  }) =>
      ApiClientConfig(
        baseUrl: baseUrl,
        getAccessToken: getAccessToken,
        refreshToken: refreshToken,
        extraHeaders: extraHeaders,
        connectTimeout: connectTimeout,
        authScheme: authScheme,
        maxRequestBodyBytes: maxRequestBodyBytes,
        maxResponseBodyBytes: maxResponseBodyBytes,
        interceptors: interceptors,
      );

  factory ApiClientConfig.withStorage({
    required String baseUrl,
    required TokenStorage tokenStorage,
    Future<bool> Function()? refreshToken,
    Map<String, String> extraHeaders = const {},
    Duration connectTimeout = const Duration(seconds: 30),
    String authScheme = 'Bearer',
    int? maxRequestBodyBytes,
    int? maxResponseBodyBytes,
    List<Interceptor> interceptors = const [],
  }) =>
      ApiClientConfig(
        baseUrl: baseUrl,
        tokenStorage: tokenStorage,
        refreshToken: refreshToken,
        extraHeaders: extraHeaders,
        connectTimeout: connectTimeout,
        authScheme: authScheme,
        maxRequestBodyBytes: maxRequestBodyBytes,
        maxResponseBodyBytes: maxResponseBodyBytes,
        interceptors: interceptors,
      );

  factory ApiClientConfig.test({
    required String baseUrl,
    required HttpAdapter adapter,
    int? maxRequestBodyBytes,
    int? maxResponseBodyBytes,
    List<Interceptor> interceptors = const [],
  }) =>
      ApiClientConfig(
        baseUrl: baseUrl,
        adapter: adapter,
        maxRequestBodyBytes: maxRequestBodyBytes,
        maxResponseBodyBytes: maxResponseBodyBytes,
        interceptors: interceptors,
      );
}

/// Public API of an HTTP client.
abstract class ApiClientInterface {
  Future<ApiResult<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> post<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> put<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> patch<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  Future<ApiResult<T>> delete<T>(
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

  Future<ApiResult<T>> _request<T>(
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
      final isSuccess = res.statusCode >= 200 && res.statusCode < 300;
      try {
        final parsed = switch (isSuccess) {
          true => _decodeSuccessBody<T>(res, responseType, decoder),
          false => _decodeErrorBody<T>(res, responseType, decoder),
        };
        if (isSuccess) {
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
        return Failure<T>(e, statusCode: res.statusCode);
      }
    } on ApiException catch (e) {
      return Failure<T>(e);
    } catch (e, st) {
      return Failure<T>(UnknownError(e.toString(), cause: e, stackTrace: st));
    }
  }

  @override
  Future<ApiResult<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      _request<T>('GET', endpoint,
          includeToken: includeToken, options: options, decoder: decoder);

  @override
  Future<ApiResult<T>> post<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      _request<T>('POST', endpoint,
          data: data,
          includeToken: includeToken,
          isMultipart: isMultipart,
          options: options,
          decoder: decoder);

  @override
  Future<ApiResult<T>> put<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      _request<T>('PUT', endpoint,
          data: data,
          includeToken: includeToken,
          isMultipart: isMultipart,
          options: options,
          decoder: decoder);

  @override
  Future<ApiResult<T>> patch<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      _request<T>('PATCH', endpoint,
          data: data,
          includeToken: includeToken,
          isMultipart: isMultipart,
          options: options,
          decoder: decoder);

  @override
  Future<ApiResult<T>> delete<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      _request<T>('DELETE', endpoint,
          includeToken: includeToken, options: options, decoder: decoder);

  Future<AdapterResponse> _send({
    required String method,
    required String endpoint,
    dynamic data,
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
  }) async {
    final resolvedOptions = _resolveOptions(options, includeToken);
    final req = InterceptedRequest(
      method: method.toUpperCase(),
      endpoint: endpoint,
      headers: _buildHeaders(resolvedOptions, isMultipart: isMultipart),
      options: resolvedOptions,
      data: data,
      isMultipart: isMultipart,
    );

    return _chain.run(request: req, transport: _transport);
  }

  Future<AdapterResponse> _transport(InterceptedRequest req) async {
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? _config.baseUrl,
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    );
    final payload = _buildPayload(req.data, isMultipart: req.isMultipart);
    return _adapter.send(
      AdapterRequest(
        method: req.method,
        url: url,
        headers: stripInternalRequestHeaders(req.headers),
        body: payload.body,
        formData: payload.formData,
        isMultipart: req.isMultipart,
        timeout: req.options.timeout ?? _config.connectTimeout,
        cancelToken: req.options.cancelToken,
        onSendProgress: req.options.onSendProgress,
        onReceiveProgress: req.options.onReceiveProgress,
        maxRequestBodyBytes: req.options.maxRequestBodyBytes,
        maxResponseBodyBytes: req.options.maxResponseBodyBytes,
      ),
    );
  }

  RequestOptions _resolveOptions(
    RequestOptions? options,
    bool includeToken,
  ) {
    final effectiveIncludeToken = options?.includeToken ?? includeToken;
    final effectiveTimeout = options?.timeout ?? _config.connectTimeout;
    final effectiveBaseUrl = options?.baseUrlOverride ?? _config.baseUrl;
    return (options ?? const RequestOptions()).copyWith(
      includeToken: effectiveIncludeToken,
      timeout: effectiveTimeout,
      baseUrlOverride: effectiveBaseUrl,
      maxRequestBodyBytes:
          options?.maxRequestBodyBytes ?? _config.maxRequestBodyBytes,
      maxResponseBodyBytes:
          options?.maxResponseBodyBytes ?? _config.maxResponseBodyBytes,
    );
  }

  Map<String, String> _buildHeaders(
    RequestOptions options, {
    required bool isMultipart,
  }) =>
      <String, String>{
        'Accept': 'application/json',
        'Accept-Language': 'en',
        if (!isMultipart) 'Content-Type': 'application/json',
        ..._config.extraHeaders,
        ...options.extraHeaders,
        ...?options.headers,
      };

  ({FormData? formData, Object? body}) _buildPayload(
    dynamic data, {
    required bool isMultipart,
  }) {
    if (isMultipart) {
      if (data is FormData) {
        return (formData: data, body: null);
      }
      if (data is Map<String, dynamic>) {
        return (formData: FormData.fromMap(data), body: null);
      }
      return (formData: null, body: null);
    }
    if (data == null) {
      return (formData: null, body: null);
    }
    return (formData: null, body: encodeBody(data));
  }

  Object? _decodeSuccessBody<T>(
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
        return _decodeJsonSuccessBody(res, decoder);
    }
  }

  Object? _decodeJsonSuccessBody<T>(
    AdapterResponse res,
    T Function(Object json)? decoder,
  ) {
    final raw = _tryDecodeUtf8(res.bodyBytes);
    if (raw == null) return null;
    final parsed = _tryParseJsonWithClassification(raw);
    if (decoder != null && parsed != null) {
      try {
        return decoder(parsed);
      } catch (e, st) {
        throw ParseError(
          'Response decoder failed.',
          cause: e,
          stackTrace: st,
        );
      }
    }
    return parsed;
  }

  Object? _decodeErrorBody<T>(
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
        final raw = _tryDecodeUtf8(res.bodyBytes, throwOnFailure: false);
        if (raw == null) return null;
        final parsed = _tryParseJson(raw, throwOnFailure: false);
        if (parsed != null) {
          if (decoder != null) {
            try {
              return decoder(parsed);
            } catch (_) {
              return parsed;
            }
          }
          return parsed;
        }
        if (_responseHandler.isHtmlOrTextResponse(raw)) return null;
        return null;
    }
  }

  String? _tryDecodeUtf8(
    List<int> bodyBytes, {
    bool throwOnFailure = true,
  }) {
    if (bodyBytes.isEmpty) return null;
    try {
      final raw = utf8.decode(bodyBytes);
      return raw.trim().isEmpty ? null : raw;
    } on FormatException catch (e, st) {
      if (!throwOnFailure) return null;
      throw ParseError(
        'Failed to decode response body as UTF-8.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  Object? _tryParseJsonWithClassification(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (e, st) {
      if (_responseHandler.isHtmlOrTextResponse(raw)) {
        throw const ParseError(
          'Expected JSON response body but received text/html.',
        );
      }
      throw ParseError(
        'Failed to parse JSON response.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  Object? _tryParseJson(String raw, {bool throwOnFailure = true}) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (e, st) {
      if (!throwOnFailure) return null;
      throw ParseError(
        'Failed to parse JSON response.',
        cause: e,
        stackTrace: st,
      );
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
