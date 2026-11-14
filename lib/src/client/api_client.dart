import '../auth/auth_interceptor.dart';
import '../auth/token_storage.dart';
import '../core/api_exception.dart';
import '../core/api_result.dart';
import '../core/form_data.dart';
import '../core/query.dart';
import '../core/request_options.dart';
import '../core/response_type.dart';
import '../http/default_http_adapter.dart';
import '../http/http_adapter.dart';
import '../http/http_stream_response.dart';
import '../interceptors/interceptor.dart';
import '../interceptors/interceptor_chain.dart';
import '../interceptors/internal_headers.dart';
import 'response_handler.dart';
import 'api_client_config.dart';
import 'response_decoder.dart';

/// Public API of an HTTP client.
///
/// Every method returns an [ApiResult]; transport, HTTP, and decode failures
/// are surfaced as a [Failure], never thrown. Pass a [decoder] to turn the
/// JSON body into `T`; without one, `T` must match the raw decoded shape.
@Deprecated(
  'Single-implementation interface with no injection point. Depend on '
  'ApiClient directly (Dart can fake concrete classes). To be removed in 2.0.0.',
)
abstract class ApiClientInterface {
  /// Sends a GET to [endpoint].
  Future<ApiResult<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  /// Sends a POST with [data] as the body, or as multipart when [isMultipart].
  Future<ApiResult<T>> post<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  /// Sends a PUT with [data] as the body, or as multipart when [isMultipart].
  Future<ApiResult<T>> put<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  /// Sends a PATCH with [data] as the body, or as multipart when [isMultipart].
  Future<ApiResult<T>> patch<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  /// Sends a DELETE to [endpoint].
  Future<ApiResult<T>> delete<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  });

  /// Sends a QUERY with [data] as the request body.
  ///
  /// QUERY is a safe, idempotent, cacheable method — like GET, but it carries
  /// a request body so complex queries can be expressed without cramming them
  /// into the URL. Standardized in RFC 10008:
  /// <https://www.rfc-editor.org/rfc/rfc10008.html>.
  Future<ApiResult<T>> query<T>(
    String endpoint,
    dynamic data, {
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
        // Only the default handler gets the configured charset; a caller's
        // own handler is used verbatim.
        _responseHandler =
            config.responseHandler ?? ResponseHandler(charset: config.charset),
        _chain = InterceptorChain([
          ..._autoAuthInterceptor(config),
          ...config.interceptors,
        ]);

  final ApiClientConfig _config;
  final HttpAdapter _adapter;
  final ResponseHandlerInterface _responseHandler;
  final InterceptorChain _chain;

  late final _decoder = ResponseDecoder(
    charset: _config.charset,
    jsonCodec: _config.responseJsonCodec,
    handler: _responseHandler,
  );

  static List<Interceptor> _autoAuthInterceptor(ApiClientConfig c) {
    final getAccessToken = c.getAccessToken;
    final storage = c.tokenStorage ??
        (getAccessToken == null ? null : _CallbackTokenStorage(getAccessToken));
    if (storage == null) return const [];
    return [
      AuthInterceptor(
        storage: storage,
        refresh: c.refreshToken,
        authScheme: c.authScheme,
        headerName: c.authHeaderName,
      ),
    ];
  }

  /// The transport this client sends through.
  HttpAdapter get adapter => _adapter;

  /// Sends a request with an arbitrary HTTP [method]. [get], [post], [put],
  /// [patch], [delete] and [query] are shorthands for this.
  Future<ApiResult<T>> request<T>(
    String method,
    String endpoint, {
    dynamic data,
    bool includeToken = true,
    bool isMultipart = false,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      _guard(() async {
        final res = await _run(
          method,
          endpoint,
          data: data,
          includeToken: includeToken,
          isMultipart: isMultipart,
          options: options,
          transport: _transport,
        );
        final responseType = options?.responseType ?? ResponseType.json;
        try {
          if (!_config.isSuccessStatus(res.statusCode)) {
            return _httpFailure(
              res,
              body: _decoder.error<T>(res, responseType, decoder),
            );
          }
          final parsed = _decoder.success<T>(res, responseType, decoder);
          final T value;
          try {
            value = parsed as T;
          } on TypeError catch (e, st) {
            // No decoder was supplied (or it returned the wrong shape) and the
            // raw JSON does not match the requested type `T`. This is a parse /
            // contract failure, not an "unknown" error.
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
        } on ApiException catch (e) {
          return Failure<T>(e, statusCode: res.statusCode);
        }
      });

  @override
  Future<ApiResult<T>> get<T>(
    String endpoint, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      request<T>('GET', endpoint,
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
      request<T>('POST', endpoint,
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
      request<T>('PUT', endpoint,
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
      request<T>('PATCH', endpoint,
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
      request<T>('DELETE', endpoint,
          includeToken: includeToken, options: options, decoder: decoder);

  @override
  Future<ApiResult<T>> query<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      request<T>('QUERY', endpoint,
          data: data,
          includeToken: includeToken,
          options: options,
          decoder: decoder);

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
  }) =>
      _guard(() async {
        final res = await _run(
          method,
          endpoint,
          data: data,
          includeToken: includeToken,
          options: options,
          transport: _streamTransport,
        );
        if (_config.isSuccessStatus(res.statusCode)) {
          return Success<HttpStreamResponse>(
            HttpStreamResponse(
              statusCode: res.statusCode,
              headers: res.headers,
              stream: res.bodyStream ?? Stream<List<int>>.value(res.bodyBytes),
            ),
            statusCode: res.statusCode,
            headers: res.headers,
          );
        }
        // The caller receives a Failure and never consumes the body, so an
        // unbuffered `bodyStream` would otherwise leave its backing
        // subscription (and the adapter's owned HTTP client) open forever.
        // Drain it to drive the adapter's cleanup; body errors are swallowed
        // because the failure is already represented by the HttpError.
        await res.bodyStream?.drain<void>().catchError((_) {});
        return _httpFailure(res);
      });

  /// Turns anything thrown while sending into a [Failure], so no request
  /// method ever throws.
  Future<ApiResult<T>> _guard<T>(Future<ApiResult<T>> Function() send) async {
    try {
      return await send();
    } on ApiException catch (e) {
      return Failure<T>(e);
    } catch (e, st) {
      return Failure<T>(UnknownError(e.toString(), cause: e, stackTrace: st));
    }
  }

  Failure<T> _httpFailure<T>(AdapterResponse res, {Object? body}) => Failure<T>(
        HttpError(
          _responseHandler.handleResponse(res) ?? 'HTTP ${res.statusCode}',
          statusCode: res.statusCode,
          body: body,
          headers: res.headers,
        ),
        statusCode: res.statusCode,
      );

  Future<AdapterResponse> _run(
    String method,
    String endpoint, {
    required dynamic data,
    required bool includeToken,
    bool isMultipart = false,
    required RequestOptions? options,
    required Transport transport,
  }) {
    final resolvedOptions = _resolveOptions(options, includeToken);
    return _chain.run(
      request: InterceptedRequest(
        method: method.toUpperCase(),
        endpoint: endpoint,
        headers: _buildHeaders(resolvedOptions, isMultipart: isMultipart),
        options: resolvedOptions,
        data: data,
        isMultipart: isMultipart,
      ),
      transport: transport,
    );
  }

  Future<AdapterResponse> _transport(InterceptedRequest req) =>
      _adapter.send(_adapterRequest(req));

  Future<AdapterResponse> _streamTransport(InterceptedRequest req) async {
    final Object adapter = _adapter;
    if (adapter is StreamingHttpAdapter) {
      return adapter.sendStreaming(_adapterRequest(req));
    }
    // Adapter can't stream: buffer once and expose the bytes as a stream so
    // `stream()` still works (just without the memory benefit).
    final res = await _transport(req);
    return AdapterResponse(
      statusCode: res.statusCode,
      headers: res.headers,
      bodyBytes: res.bodyBytes,
      reasonPhrase: res.reasonPhrase,
      bodyStream: Stream<List<int>>.value(res.bodyBytes),
    );
  }

  AdapterRequest _adapterRequest(InterceptedRequest req) {
    final payload = _buildPayload(req.data, isMultipart: req.isMultipart);
    return AdapterRequest(
      method: req.method,
      url: buildUri(
        baseUrl: req.options.baseUrlOverride ?? _config.baseUrl,
        endpoint: req.endpoint,
        queryParameters: req.options.queryParameters,
        encoder: _config.queryEncoder,
      ),
      headers: stripInternalHeaders(req.headers),
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
  }

  RequestOptions _resolveOptions(
    RequestOptions? options,
    bool includeToken,
  ) {
    // Fail-safe AND: the token is attached only when BOTH the method argument
    // and the per-request options permit it, so the options default (`true`)
    // can never override an explicit `includeToken: false` and leak the
    // Authorization header onto a request the caller excluded.
    final effectiveIncludeToken =
        includeToken && (options?.includeToken ?? true);
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
    // the default `Content-Type` rather than sit alongside it. Later sources
    // win; the latest casing for a given name is preserved.
    final merged = <String, String>{};
    final canonical = <String, String>{}; // lower-case name -> stored key
    void put(String key, String value) {
      final lower = key.toLowerCase();
      final existing = canonical[lower];
      if (existing != null) merged.remove(existing);
      merged[key] = value;
      canonical[lower] = key;
    }

    final defaults = _config.defaultHeaders;
    if (defaults != null) {
      // A full replacement set: honour it verbatim. On multipart requests the
      // transport (DefaultHttpAdapter) strips Content-Type so it can set the
      // boundary, so a Content-Type here is handled there exactly as for the
      // built-in defaults.
      defaults.forEach(put);
    } else {
      put('Accept', _config.defaultAccept);
      put('Accept-Language', _config.defaultAcceptLanguage);
      if (!isMultipart) put('Content-Type', _config.defaultContentType);
    }
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
    return (formData: null, body: _config.bodySerializer.encode(data));
  }

  /// Releases the underlying adapter's resources. Call when done with the
  /// client.
  void close() => _adapter.close();
}

class _CallbackTokenStorage extends TokenStorage {
  _CallbackTokenStorage(this._cb);
  final Future<String?> Function() _cb;

  @override
  Future<String?> getAccessToken() => _cb();
  @override
  Future<void> setAccessToken(String? token) async {}
}
