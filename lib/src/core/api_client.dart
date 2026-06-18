import 'dart:convert';

import '../auth/auth_interceptor.dart';
import '../auth/token_storage.dart';
import '../http/default_http_adapter.dart';
import '../http/http_adapter.dart';
import '../http/http_stream_response.dart';
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
          final T value;
          try {
            value = parsed as T;
          } on TypeError catch (e, st) {
            // No decoder was supplied (or it returned the wrong shape) and the
            // raw JSON does not match the requested type `T`. This is a parse /
            // contract failure, not an "unknown" error — surface it as such so
            // the sealed-result contract stays honest.
            throw ParseError(
              'Response body could not be cast to the expected type. '
              'Supply a `decoder` for non-primitive types.',
              cause: e,
              stackTrace: st,
            );
          }
          return Success<T>(
            value,
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

  /// Sends a request and returns the response body as a live byte stream
  /// instead of buffering it. Use for large downloads or incremental
  /// (SSE/NDJSON) bodies.
  ///
  /// Runs the full interceptor chain (so auth, retries, and headers apply),
  /// but cache and dedup pass streaming responses through untouched since an
  /// unbuffered body cannot be stored or shared.
  Future<ApiResult<HttpStreamResponse>> stream(
    String endpoint, {
    String method = 'GET',
    dynamic data,
    bool includeToken = true,
    RequestOptions? options,
  }) async {
    try {
      final resolvedOptions = _resolveOptions(options, includeToken);
      final req = InterceptedRequest(
        method: method.toUpperCase(),
        endpoint: endpoint,
        headers: _buildHeaders(resolvedOptions, isMultipart: false),
        options: resolvedOptions,
        data: data,
      );
      final res = await _chain.run(request: req, transport: _streamTransport);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final streamed = HttpStreamResponse(
          statusCode: res.statusCode,
          headers: res.headers,
          stream: res.bodyStream ?? Stream<List<int>>.value(res.bodyBytes),
        );
        return Success<HttpStreamResponse>(
          streamed,
          statusCode: res.statusCode,
          headers: res.headers,
        );
      }
      // Error response: the caller receives a Failure and never consumes the
      // body, so an unbuffered `bodyStream` would otherwise leave its backing
      // subscription (and the adapter's owned HTTP client) open forever. Drain
      // it to drive the adapter's cleanup. We swallow body errors here because
      // the failure is already represented by the HttpError below.
      final bodyStream = res.bodyStream;
      if (bodyStream != null) {
        await bodyStream.drain<void>().catchError((_) {});
      }
      final msg =
          _responseHandler.handleResponse(res) ?? 'HTTP ${res.statusCode}';
      return Failure<HttpStreamResponse>(
        HttpError(msg, statusCode: res.statusCode, headers: res.headers),
        statusCode: res.statusCode,
      );
    } on ApiException catch (e) {
      return Failure<HttpStreamResponse>(e);
    } catch (e, st) {
      return Failure<HttpStreamResponse>(
        UnknownError(e.toString(), cause: e, stackTrace: st),
      );
    }
  }

  Future<AdapterResponse> _transport(InterceptedRequest req) =>
      _dispatch(req, streaming: false);

  Future<AdapterResponse> _streamTransport(InterceptedRequest req) =>
      _dispatch(req, streaming: true);

  Future<AdapterResponse> _dispatch(
    InterceptedRequest req, {
    required bool streaming,
  }) async {
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? _config.baseUrl,
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    );
    final payload = _buildPayload(req.data, isMultipart: req.isMultipart);
    final adapterRequest = AdapterRequest(
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
    );
    if (!streaming) return _adapter.send(adapterRequest);
    final adapter = _adapter;
    if (adapter is StreamingHttpAdapter) {
      return (adapter as StreamingHttpAdapter).sendStreaming(adapterRequest);
    }
    // Adapter can't stream: buffer once and expose the bytes as a stream so
    // `stream()` still works (just without the memory benefit).
    final res = await _adapter.send(adapterRequest);
    return AdapterResponse(
      statusCode: res.statusCode,
      headers: res.headers,
      bodyBytes: res.bodyBytes,
      reasonPhrase: res.reasonPhrase,
      bodyStream: Stream<List<int>>.value(res.bodyBytes),
    );
  }

  RequestOptions _resolveOptions(
    RequestOptions? options,
    bool includeToken,
  ) {
    // Fail-safe AND: the token is attached only when BOTH the method argument
    // and the per-request options permit it. Suppressing the token is a
    // deliberate security decision; if either knob says "no token", we honour
    // it. Previously `options?.includeToken ?? includeToken` let the options
    // default (`true`) silently override an explicit `includeToken: false`
    // method argument, leaking the Authorization header onto a request the
    // caller had explicitly excluded.
    final effectiveIncludeToken = includeToken && (options?.includeToken ?? true);
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
  }) {
    // Merge case-insensitively: HTTP header names are case-insensitive
    // (RFC 7230 §3.2), so a caller override like `content-type` must REPLACE
    // the default `Content-Type` rather than sit alongside it. A naive map
    // spread keyed by the literal string emitted BOTH, putting two conflicting
    // Content-Type headers on the wire and letting the server pick either one.
    // Later sources win; the latest casing for a given name is preserved.
    final merged = <String, String>{};
    final canonical = <String, String>{}; // lower-case name -> stored key
    void put(String key, String value) {
      final lower = key.toLowerCase();
      final existing = canonical[lower];
      if (existing != null) merged.remove(existing);
      merged[key] = value;
      canonical[lower] = key;
    }

    put('Accept', 'application/json');
    put('Accept-Language', 'en');
    if (!isMultipart) put('Content-Type', 'application/json');
    _config.extraHeaders.forEach(put);
    options.extraHeaders.forEach(put);
    options.headers?.forEach(put);
    return merged;
  }

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
