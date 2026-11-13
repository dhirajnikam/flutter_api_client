import '../core/api_exception.dart';
import '../core/response_type.dart';
import '../core/serialization.dart';
import '../http/http_adapter.dart';
import '../response/response_handler.dart';

/// Turns a response body into the value a caller asked for.
class ResponseDecoder {
  ResponseDecoder({
    required this.charset,
    required this.jsonCodec,
    required this.handler,
  });

  final Charset charset;
  final ResponseJsonCodec jsonCodec;
  final ResponseHandlerInterface handler;

  /// Body of a success response. Throws a [ParseError] when it cannot be
  /// decoded, so a decode failure is never reported as an unknown error.
  Object? success<T>(
    AdapterResponse res,
    ResponseType type,
    T Function(Object json)? decoder,
  ) {
    switch (type) {
      case ResponseType.bytes:
      case ResponseType.stream:
        return res.bodyBytes;
      case ResponseType.plainText:
        return _text(res.bodyBytes);
      case ResponseType.json:
        final parsed = _json(res.bodyBytes);
        if (decoder == null || parsed == null) return parsed;
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
  }

  /// Body of an error response. It is only informational (the failure is
  /// already an `HttpError`), so a missing, malformed, or HTML body degrades
  /// to `null`, and a failing [decoder] to the raw JSON.
  Object? error<T>(
    AdapterResponse res,
    ResponseType type,
    T Function(Object json)? decoder,
  ) {
    switch (type) {
      case ResponseType.bytes:
      case ResponseType.stream:
        return res.bodyBytes;
      case ResponseType.plainText:
        try {
          return _text(res.bodyBytes);
        } on ParseError {
          return null;
        }
      case ResponseType.json:
        final Object? parsed;
        try {
          parsed = _json(res.bodyBytes);
        } on ParseError {
          return null;
        }
        if (decoder == null || parsed == null) return parsed;
        try {
          return decoder(parsed);
        } catch (_) {
          return parsed;
        }
    }
  }

  String _text(List<int> bodyBytes) {
    try {
      return charset.decode(bodyBytes);
    } on FormatException catch (e, st) {
      throw ParseError(
        'Failed to decode response body with the configured charset.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  /// The parsed JSON body, or `null` when the body is empty or blank.
  Object? _json(List<int> bodyBytes) {
    if (bodyBytes.isEmpty) return null;
    final raw = _text(bodyBytes);
    if (raw.trim().isEmpty) return null;
    try {
      return jsonCodec.decode(raw);
    } on FormatException catch (e, st) {
      if (handler.isHtmlOrTextResponse(raw)) {
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
}
