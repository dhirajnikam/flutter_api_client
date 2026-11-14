import 'dart:convert';

import '../core/serialization.dart';
import '../http/http_adapter.dart';

/// Pluggable response error message extractor.
abstract class ResponseHandlerInterface {
  /// Returns an error message for non-2xx responses, null otherwise.
  String? handleResponse(AdapterResponse response);

  /// True if the body looks like HTML/plain text instead of JSON.
  bool isHtmlOrTextResponse(String responseBody);
}

/// Default response handler that extracts a human-readable message from a
/// JSON error envelope and detects HTML / plain-text bodies.
class ResponseHandler implements ResponseHandlerInterface {
  const ResponseHandler({this.charset = const Utf8Charset()});

  /// Decodes response bytes before message extraction. Malformed bytes
  /// degrade to a generic message rather than throwing.
  final Charset charset;

  @override
  String? handleResponse(AdapterResponse res) {
    final isSuccess = res.statusCode >= 200 && res.statusCode < 300;
    try {
      final body = charset.decode(res.bodyBytes);

      final trimmed = body.trim();
      if (trimmed.isEmpty) {
        return isSuccess ? null : 'Server returned an empty response';
      }
      if (isHtmlOrTextResponse(trimmed)) {
        return 'The server returned an invalid response. Please try again later.';
      }
      try {
        final decoded = jsonDecode(body);
        if (isSuccess) return null;
        if (decoded is Map<String, dynamic>) {
          return _extractMessage(decoded['message'] ?? decoded['error']);
        }
        return decoded.toString();
      } on FormatException {
        return isSuccess
            ? null
            : 'Failed to parse the response. Please try again later.';
      }
    } catch (_) {
      return 'Failed to process the response.';
    }
  }

  String _extractMessage(dynamic error) {
    if (error == null) return 'An unknown error occurred.';
    if (error is String) {
      return error.isNotEmpty ? error : 'An unknown error occurred.';
    }
    if (error is List) return error.join(', ');
    if (error is Map<String, dynamic>) {
      final buf = StringBuffer();
      error.forEach((k, v) {
        if (v is List) {
          buf.writeln('$k: ${v.join(', ')}');
        } else {
          buf.writeln('$v');
        }
      });
      final out = buf.toString().trim();
      return out.isEmpty ? 'An unexpected error occurred.' : out;
    }
    return error.toString();
  }

  @override
  bool isHtmlOrTextResponse(String body) {
    final t = body.trim();
    if (t.isEmpty) return false;
    // Case-insensitive prefix match so `<!doctype html>`, `<!DOCTYPE HTML ...>`
    // and `<HTML>` are all classified as HTML. (HTML markup is case-insensitive
    // and real servers emit mixed/lower case.)
    final lower = t.toLowerCase();
    if (lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        (lower.contains('<head>') && lower.contains('<body>'))) {
      return true;
    }
    if (t.length < 5 && !t.startsWith('{') && !t.startsWith('[')) {
      return true;
    }
    return false;
  }
}
