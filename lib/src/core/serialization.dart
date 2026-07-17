import 'dart:convert';

import 'query.dart';

/// Pluggable body-charset codec.
///
/// Controls how string request bodies are turned into bytes and how raw
/// response bytes are turned back into a `String` before JSON parsing or
/// plain-text decoding. Defaults to UTF-8 ([Utf8Charset]).
///
/// Contract for implementers:
/// - [encode] must be the inverse of [decode] for any string it produced.
/// - [decode] **must throw a [FormatException]** on malformed input. The
///   client relies on this to classify a bad body as a typed `ParseError`
///   rather than an opaque failure; a lenient decoder that swallows errors
///   would silently mask corrupt responses.
abstract interface class Charset {
  /// Decodes [bytes] into a `String`, throwing [FormatException] if the bytes
  /// are not valid in this charset.
  String decode(List<int> bytes);

  /// Encodes [s] into bytes in this charset.
  List<int> encode(String s);
}

/// Default [Charset] backed by `dart:convert`'s strict UTF-8 codec.
class Utf8Charset implements Charset {
  /// Creates the UTF-8 charset. `const` so it can be a default field value.
  const Utf8Charset();

  @override
  String decode(List<int> bytes) => utf8.decode(bytes);

  @override
  List<int> encode(String s) => utf8.encode(s);
}

/// Turns a request payload into the encoded body handed to the transport.
///
/// The return value becomes `AdapterRequest.body`, so it must be a type the
/// adapter understands — for [DefaultHttpAdapter] that is `String`,
/// `List<int>`, or `null`. Returning `null` sends no body.
///
/// Implement this to send a body format other than JSON (e.g. form-urlencoded,
/// protobuf, or MessagePack). The default is [JsonRequestBodySerializer].
abstract interface class RequestBodySerializer {
  /// Encodes [data] into a transport body, or `null` for no body.
  Object? encode(Object? data);
}

/// Default [RequestBodySerializer]: JSON via `dart:convert`, bytes via a
/// [Charset] (UTF-8 by default).
///
/// Behaviour, matching the pre-1.3.0 built-in encoder exactly:
/// - `null` -> `null` (no body)
/// - `String` -> charset-encoded bytes
/// - `List<int>` -> passed through unchanged
/// - anything else -> `charset.encode(jsonEncode(data))`
class JsonRequestBodySerializer implements RequestBodySerializer {
  /// Creates the default JSON serializer using [charset] (UTF-8 by default).
  const JsonRequestBodySerializer({this.charset = const Utf8Charset()});

  /// Charset used to encode `String` bodies and JSON output.
  final Charset charset;

  @override
  Object? encode(Object? data) {
    if (data == null) return null;
    if (data is String) return charset.encode(data);
    if (data is List<int>) return data;
    return charset.encode(jsonEncode(data));
  }
}

/// Parses a decoded response `String` into a JSON value.
///
/// Implement this to plug in a custom JSON parser (e.g. one with a reviver, a
/// big-number policy, or a faster codec). The default is
/// [DefaultResponseJsonCodec].
///
/// Contract: [decode] **must throw a [FormatException]** on invalid JSON so the
/// client can surface a typed `ParseError`.
abstract interface class ResponseJsonCodec {
  /// Parses [source] as JSON, throwing [FormatException] when it is invalid.
  Object? decode(String source);
}

/// Default [ResponseJsonCodec] delegating to `dart:convert`'s `jsonDecode`.
class DefaultResponseJsonCodec implements ResponseJsonCodec {
  /// Creates the default JSON codec. `const` so it can be a default value.
  const DefaultResponseJsonCodec();

  @override
  Object? decode(String source) => jsonDecode(source);
}

/// Immutable bundle of the client's fine-grained customization knobs.
///
/// Every field is nullable; a `null` field means "use the built-in default",
/// so an empty `const ClientCustomization()` preserves the pre-1.3.0 behaviour
/// exactly. It exists so the convenience factories
/// (`ApiClientConfig.withToken` / `.withStorage` / `.test`) can expose the full
/// customization surface through a single parameter instead of a long list.
///
/// The individual knobs are also available directly on the main
/// [ApiClientConfig] constructor for discoverability.
class ClientCustomization {
  /// Creates a customization bundle. All fields are optional.
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

  /// Body charset. Built-in default: [Utf8Charset].
  final Charset? charset;

  /// URL query-string encoder. Built-in default: `const QueryEncoder()`.
  final QueryEncoder? queryEncoder;

  /// Authorization header name. Built-in default: `Authorization`.
  final String? authHeaderName;

  /// Predicate deciding whether a status code is a success. Built-in default:
  /// `200 <= code < 300`.
  final bool Function(int statusCode)? isSuccessStatus;
}
