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
import 'serialization.dart';

/// Default success predicate: the standard 2xx range.
bool _defaultIsSuccessStatus(int statusCode) =>
    statusCode >= 200 && statusCode < 300;

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
    this.defaultHeaders,
    this.defaultAccept = 'application/json',
    this.defaultAcceptLanguage = 'en',
    this.defaultContentType = 'application/json',
    this.authHeaderName = 'Authorization',
    this.bodySerializer = const JsonRequestBodySerializer(),
    this.responseJsonCodec = const DefaultResponseJsonCodec(),
    this.charset = const Utf8Charset(),
    this.queryEncoder = const QueryEncoder(),
    bool Function(int statusCode)? isSuccessStatus,
  }) : isSuccessStatus = isSuccessStatus ?? _defaultIsSuccessStatus;

  /// Base URL every endpoint is resolved against.
  final String baseUrl;

  /// Token store used by the built-in auth interceptor. Mutually exclusive
  /// with [getAccessToken].
  final TokenStorage? tokenStorage;

  /// Supplies the access token on demand. Mutually exclusive with
  /// [tokenStorage].
  final Future<String?> Function()? getAccessToken;

  /// Called on a 401 to refresh credentials; returns true if it succeeded.
  final Future<bool> Function()? refreshToken;

  /// Headers added to every request.
  final Map<String, String> extraHeaders;

  /// Default per-request timeout.
  final Duration connectTimeout;

  /// Authorization scheme prefix (e.g. `Bearer`). Empty sends a bare token.
  final String authScheme;

  /// Rejects requests whose encoded body exceeds this many bytes.
  final int? maxRequestBodyBytes;

  /// Rejects responses whose buffered body exceeds this many bytes.
  final int? maxResponseBodyBytes;

  /// Extracts error messages from non-2xx responses. Defaults to
  /// [ResponseHandler].
  final ResponseHandlerInterface? responseHandler;

  /// Interceptors run in order, after the auto-configured auth interceptor.
  final List<Interceptor> interceptors;

  /// Transport. Defaults to [DefaultHttpAdapter] when omitted.
  final HttpAdapter? adapter;

  /// When non-null, replaces the entire built-in default-header block
  /// (`Accept`, `Accept-Language`, and — for non-multipart — `Content-Type`).
  /// Per-request `headers`/`extraHeaders` still override these. When null, the
  /// granular [defaultAccept]/[defaultAcceptLanguage]/[defaultContentType]
  /// fields are used.
  final Map<String, String>? defaultHeaders;

  /// Default `Accept` header. Ignored when [defaultHeaders] is set.
  final String defaultAccept;

  /// Default `Accept-Language` header (the client's locale). Ignored when
  /// [defaultHeaders] is set.
  final String defaultAcceptLanguage;

  /// Default `Content-Type` for non-multipart requests. Ignored when
  /// [defaultHeaders] is set.
  final String defaultContentType;

  /// Header the auth token is written to by the built-in auth interceptor.
  /// Defaults to `Authorization`.
  final String authHeaderName;

  /// Encodes request bodies before they reach the transport. Defaults to JSON.
  final RequestBodySerializer bodySerializer;

  /// Parses JSON response bodies. Defaults to `dart:convert`'s `jsonDecode`.
  final ResponseJsonCodec responseJsonCodec;

  /// Charset used to encode string bodies and decode response bytes. Defaults
  /// to UTF-8.
  final Charset charset;

  /// Serializes URL query parameters. Defaults to repeated-key lists and
  /// bracketed nested maps.
  final QueryEncoder queryEncoder;

  /// Decides whether a response status code is a success (`Success`) or a
  /// failure (`Failure`). Defaults to `200 <= code < 300`.
  final bool Function(int statusCode) isSuccessStatus;

  /// Config whose auth token comes from a [getAccessToken] callback.
  ///
  /// Pass [customization] to configure default headers, serialization, query
  /// encoding, the auth header name, or the success predicate through a single
  /// parameter (see [ClientCustomization]).
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
    ClientCustomization customization = const ClientCustomization(),
  }) =>
      _build(
        baseUrl: baseUrl,
        getAccessToken: getAccessToken,
        refreshToken: refreshToken,
        extraHeaders: extraHeaders,
        connectTimeout: connectTimeout,
        authScheme: authScheme,
        maxRequestBodyBytes: maxRequestBodyBytes,
        maxResponseBodyBytes: maxResponseBodyBytes,
        interceptors: interceptors,
        customization: customization,
      );

  /// Config whose auth token is read from (and refreshed into) [tokenStorage].
  ///
  /// Pass [customization] to configure the extra options described on
  /// [ClientCustomization].
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
    ClientCustomization customization = const ClientCustomization(),
  }) =>
      _build(
        baseUrl: baseUrl,
        tokenStorage: tokenStorage,
        refreshToken: refreshToken,
        extraHeaders: extraHeaders,
        connectTimeout: connectTimeout,
        authScheme: authScheme,
        maxRequestBodyBytes: maxRequestBodyBytes,
        maxResponseBodyBytes: maxResponseBodyBytes,
        interceptors: interceptors,
        customization: customization,
      );

  /// Config with no auth, wired to an injected [adapter] (e.g. a mock) for
  /// tests.
  ///
  /// Pass [customization] to exercise custom serialization/query encoding in
  /// tests (see [ClientCustomization]).
  factory ApiClientConfig.test({
    required String baseUrl,
    required HttpAdapter adapter,
    int? maxRequestBodyBytes,
    int? maxResponseBodyBytes,
    List<Interceptor> interceptors = const [],
    ClientCustomization customization = const ClientCustomization(),
  }) =>
      _build(
        baseUrl: baseUrl,
        adapter: adapter,
        maxRequestBodyBytes: maxRequestBodyBytes,
        maxResponseBodyBytes: maxResponseBodyBytes,
        interceptors: interceptors,
        customization: customization,
      );

  /// Shared builder that resolves a [ClientCustomization] bundle onto the
  /// primary constructor, keeping the null-means-default semantics in one place
  /// so the three factories stay in sync.
  static ApiClientConfig _build({
    required String baseUrl,
    TokenStorage? tokenStorage,
    Future<String?> Function()? getAccessToken,
    Future<bool> Function()? refreshToken,
    Map<String, String> extraHeaders = const {},
    Duration connectTimeout = const Duration(seconds: 30),
    String authScheme = 'Bearer',
    int? maxRequestBodyBytes,
    int? maxResponseBodyBytes,
    List<Interceptor> interceptors = const [],
    HttpAdapter? adapter,
    required ClientCustomization customization,
  }) =>
      ApiClientConfig(
        baseUrl: baseUrl,
        tokenStorage: tokenStorage,
        getAccessToken: getAccessToken,
        refreshToken: refreshToken,
        extraHeaders: extraHeaders,
        connectTimeout: connectTimeout,
        authScheme: authScheme,
        maxRequestBodyBytes: maxRequestBodyBytes,
        maxResponseBodyBytes: maxResponseBodyBytes,
        interceptors: interceptors,
        adapter: adapter,
        defaultHeaders: customization.defaultHeaders,
        defaultAccept: customization.defaultAccept ?? 'application/json',
        defaultAcceptLanguage: customization.defaultAcceptLanguage ?? 'en',
        defaultContentType:
            customization.defaultContentType ?? 'application/json',
        authHeaderName: customization.authHeaderName ?? 'Authorization',
        bodySerializer:
            customization.bodySerializer ?? const JsonRequestBodySerializer(),
        responseJsonCodec:
            customization.responseJsonCodec ?? const DefaultResponseJsonCodec(),
        charset: customization.charset ?? const Utf8Charset(),
        queryEncoder: customization.queryEncoder ?? const QueryEncoder(),
        isSuccessStatus: customization.isSuccessStatus,
      );
}

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
          headerName: c.authHeaderName,
        ),
      ];
    }
    if (c.getAccessToken != null) {
      return [
        AuthInterceptor(
          storage: _CallbackTokenStorage(c.getAccessToken!),
          refresh: c.refreshToken,
          authScheme: c.authScheme,
          headerName: c.authHeaderName,
        ),
      ];
    }
    return const [];
  }

  /// The transport this client sends through.
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
      final isSuccess = _config.isSuccessStatus(res.statusCode);
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

  @override
  Future<ApiResult<T>> query<T>(
    String endpoint,
    dynamic data, {
    bool includeToken = true,
    RequestOptions? options,
    T Function(Object json)? decoder,
  }) =>
      _request<T>('QUERY', endpoint,
          data: data,
          includeToken: includeToken,
          options: options,
          decoder: decoder);

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
      if (_config.isSuccessStatus(res.statusCode)) {
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
      encoder: _config.queryEncoder,
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

  Object? _decodeSuccessBody<T>(
    AdapterResponse res,
    ResponseType type,
    T Function(Object json)? decoder,
  ) {
    switch (type) {
      case ResponseType.bytes:
        return res.bodyBytes;
      case ResponseType.plainText:
        return _decodePlainText(res.bodyBytes);
      case ResponseType.stream:
        return res.bodyBytes;
      case ResponseType.json:
        return _decodeJsonSuccessBody(res, decoder);
    }
  }

  /// Decodes a plain-text body, surfacing an invalid UTF-8 sequence as a typed
  /// [ParseError] rather than letting the raw `FormatException` escape and be
  /// reclassified as an opaque `UnknownError`. Mirrors the JSON path's typing so
  /// "a decode failure is a ParseError" holds for every response mode. An empty
  /// body decodes to the empty string (unchanged).
  String _decodePlainText(List<int> bodyBytes) {
    try {
      return _config.charset.decode(bodyBytes);
    } on FormatException catch (e, st) {
      throw ParseError(
        'Failed to decode response body with the configured charset.',
        cause: e,
        stackTrace: st,
      );
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
        // On the error path the body is only informational (the failure is
        // already represented by the HttpError), so a malformed body degrades
        // to null instead of throwing — never an escaping FormatException.
        try {
          return _config.charset.decode(res.bodyBytes);
        } on FormatException {
          return null;
        }
      case ResponseType.stream:
        return res.bodyBytes;
      case ResponseType.json:
        final raw = _tryDecodeUtf8(res.bodyBytes, throwOnFailure: false);
        if (raw == null) return null;
        final parsed = _tryParseJson(raw, throwOnFailure: false);
        // A body that is missing, malformed, or HTML is only informational on
        // the error path (the failure is already the HttpError), so it degrades
        // to null rather than throwing.
        if (parsed == null) return null;
        if (decoder == null) return parsed;
        try {
          return decoder(parsed);
        } catch (_) {
          return parsed;
        }
    }
  }

  String? _tryDecodeUtf8(
    List<int> bodyBytes, {
    bool throwOnFailure = true,
  }) {
    if (bodyBytes.isEmpty) return null;
    try {
      final raw = _config.charset.decode(bodyBytes);
      return raw.trim().isEmpty ? null : raw;
    } on FormatException catch (e, st) {
      if (!throwOnFailure) return null;
      throw ParseError(
        'Failed to decode response body with the configured charset.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  Object? _tryParseJsonWithClassification(String raw) {
    try {
      return _config.responseJsonCodec.decode(raw);
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
      return _config.responseJsonCodec.decode(raw);
    } on FormatException catch (e, st) {
      if (!throwOnFailure) return null;
      throw ParseError(
        'Failed to parse JSON response.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  /// Releases the underlying adapter's resources. Call when done with the
  /// client.
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
