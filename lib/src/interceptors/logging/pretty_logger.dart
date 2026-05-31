import 'dart:convert';

import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';

/// Pretty, line-broken request/response logger with optional ANSI colors
/// and header redaction.
class PrettyLogger extends Interceptor {
  PrettyLogger({
    this.printer = print,
    this.redactHeaders = const {
      'authorization',
      'cookie',
      'set-cookie',
      'proxy-authorization',
      'x-api-key',
      'x-auth-token',
    },
    this.redactBodyKeys = const {
      'password',
      'passwd',
      'pwd',
      'secret',
      'token',
      'access_token',
      'refresh_token',
      'api_key',
      'apikey',
      'client_secret',
      'credit_card',
      'card_number',
    },
    this.requestBody = true,
    this.responseBody = true,
    this.useColors = true,
  });

  final void Function(String) printer;
  final Set<String> redactHeaders;
  final Set<String> redactBodyKeys;
  final bool requestBody;
  final bool responseBody;
  final bool useColors;

  static const _reset = '\u001B[0m';
  static const _cyan = '\u001B[36m';
  static const _green = '\u001B[32m';
  static const _red = '\u001B[31m';
  static const _grey = '\u001B[90m';

  late final Set<String> _normalizedRedactBodyKeys = {
    for (final key in redactBodyKeys) _normalizeKey(key),
  };

  String _c(String code, String s) => useColors ? '$code$s$_reset' : s;

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    final buf = StringBuffer();
    buf.writeln(_c(_cyan, '┌─── ${req.method} ${req.endpoint} ───'));
    req.headers.forEach((k, v) {
      buf.writeln(_c(_grey, '│ $k: ${_redactHeaderValue(k, v)}'));
    });
    if (requestBody && req.data != null && !req.isMultipart) {
      final body =
          req.data is String ? req.data as String : jsonEncode(req.data);
      buf.writeln(_c(_grey, '│ body: ${_redactJsonBody(body)}'));
    }
    buf.writeln(_c(_cyan, '└───────────────'));
    printer(buf.toString());
    return ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    final color = res.statusCode >= 200 && res.statusCode < 300 ? _green : _red;
    final buf = StringBuffer();
    buf.writeln(
      _c(color, '┌─── ${res.statusCode} ${req.method} ${req.endpoint} ───'),
    );
    res.headers.forEach((k, v) {
      buf.writeln(_c(_grey, '│ $k: ${_redactHeaderValue(k, v)}'));
    });
    if (responseBody) {
      try {
        final body = utf8.decode(res.bodyBytes);
        if (body.isNotEmpty) {
          final preview =
              body.length > 2000 ? '${body.substring(0, 2000)}…' : body;
          buf.writeln(_c(_grey, '│ body: ${_redactJsonBody(preview)}'));
        }
      } catch (_) {}
    }
    buf.writeln(_c(color, '└───────────────'));
    printer(buf.toString());
    return ResolveResult(res);
  }

  String _redactHeaderValue(String name, String value) =>
      redactHeaders.contains(name.toLowerCase()) ? '<redacted>' : value;

  /// Redacts values for keys in [redactBodyKeys] from a JSON body string.
  /// Returns the original [body] if it isn't valid JSON.
  String _redactJsonBody(String body) {
    if (_normalizedRedactBodyKeys.isEmpty) return body;
    try {
      final decoded = jsonDecode(body);
      final redacted = _redactValue(decoded);
      return jsonEncode(redacted);
    } catch (_) {
      return body;
    }
  }

  dynamic _redactValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        result[key] = _normalizedRedactBodyKeys.contains(_normalizeKey(key))
            ? '<redacted>'
            : _redactValue(entry.value);
      }
      return result;
    }
    if (value is List) {
      return value.map(_redactValue).toList(growable: false);
    }
    return value;
  }

  String _normalizeKey(String key) {
    final buffer = StringBuffer();
    for (final code in key.codeUnits) {
      if (code >= 48 && code <= 57) {
        buffer.writeCharCode(code);
      } else if (code >= 65 && code <= 90) {
        buffer.writeCharCode(code + 32);
      } else if (code >= 97 && code <= 122) {
        buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    printer(_c(_red, '✗ ${req.method} ${req.endpoint}: $error'));
    return RejectResult(error);
  }
}
