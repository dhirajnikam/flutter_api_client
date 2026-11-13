import '../auth/token_storage.dart';
import '../core/query.dart';
import '../core/serialization.dart';
import '../http/http_adapter.dart';
import '../interceptors/interceptor.dart';
import '../response/response_handler.dart';

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
    this.defaultAccept = _json,
    this.defaultAcceptLanguage = _language,
    this.defaultContentType = _json,
    this.authHeaderName = _authHeader,
    this.bodySerializer = const JsonRequestBodySerializer(),
    this.responseJsonCodec = const DefaultResponseJsonCodec(),
    this.charset = const Utf8Charset(),
    this.queryEncoder = const QueryEncoder(),
    bool Function(int statusCode)? isSuccessStatus,
  }) : isSuccessStatus = isSuccessStatus ?? _defaultIsSuccessStatus;

  static const _json = 'application/json';
  static const _language = 'en';
  static const _authHeader = 'Authorization';

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

  /// Charset used to decode response bytes. Defaults to UTF-8. Request bodies
  /// are encoded by [bodySerializer]; pass
  /// `JsonRequestBodySerializer(charset: …)` to match.
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
        defaultAccept: customization.defaultAccept ?? _json,
        defaultAcceptLanguage: customization.defaultAcceptLanguage ?? _language,
        defaultContentType: customization.defaultContentType ?? _json,
        authHeaderName: customization.authHeaderName ?? _authHeader,
        bodySerializer:
            customization.bodySerializer ?? const JsonRequestBodySerializer(),
        responseJsonCodec:
            customization.responseJsonCodec ?? const DefaultResponseJsonCodec(),
        charset: customization.charset ?? const Utf8Charset(),
        queryEncoder: customization.queryEncoder ?? const QueryEncoder(),
        isSuccessStatus: customization.isSuccessStatus,
      );
}

/// Immutable bundle of the client's fine-grained customization knobs.
///
/// Every field is nullable; a `null` field means "use the built-in default".
/// It exists so the convenience factories
/// (`ApiClientConfig.withToken` / `.withStorage` / `.test`) can expose the full
/// customization surface through a single parameter instead of a long list.
///
/// The individual knobs are also available directly on the main
/// [ApiClientConfig] constructor for discoverability.
@Deprecated(
  'Pass these options to the ApiClientConfig constructor '
  'directly. To be removed in 2.0.0.',
)
class ClientCustomization {
  const ClientCustomization({
    this.defaultHeaders,
    this.defaultAccept,
    this.defaultAcceptLanguage,
    this.defaultContentType,
    this.bodySerializer,
    this.responseJsonCodec,
    this.charset,
    this.queryEncoder,
    this.authHeaderName,
    this.isSuccessStatus,
  });

  /// Replaces the entire built-in default-header block when non-null.
  final Map<String, String>? defaultHeaders;

  /// Default `Accept` header value. Built-in default: `application/json`.
  final String? defaultAccept;

  /// Default `Accept-Language` header value (the locale). Built-in
  /// default: `en`.
  final String? defaultAcceptLanguage;

  /// Default `Content-Type` for non-multipart requests. Built-in default:
  /// `application/json`.
  final String? defaultContentType;

  /// Request body serializer. Built-in default: [JsonRequestBodySerializer].
  final RequestBodySerializer? bodySerializer;

  /// Response JSON parser. Built-in default: [DefaultResponseJsonCodec].
  final ResponseJsonCodec? responseJsonCodec;

  /// Response body charset. Built-in default: [Utf8Charset].
  final Charset? charset;

  /// URL query-string encoder. Built-in default: `const QueryEncoder()`.
  final QueryEncoder? queryEncoder;

  /// Authorization header name. Built-in default: `Authorization`.
  final String? authHeaderName;

  /// Predicate deciding whether a status code is a success. Built-in default:
  /// `200 <= code < 300`.
  final bool Function(int statusCode)? isSuccessStatus;
}
