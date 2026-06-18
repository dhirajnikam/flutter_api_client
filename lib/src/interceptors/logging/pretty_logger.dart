import 'dart:convert';

import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import 'redaction.dart';

/// Pretty, line-broken request/response logger with optional ANSI colors
/// and header redaction.
class PrettyLogger extends Interceptor {
  /// Creates a pretty logger. All knobs have safe defaults; secrets in common
  /// header and body fields are redacted out of the box.
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

  /// Sink each formatted block is written to. Defaults to `print`.
  final void Function(String) printer;

  /// Header names whose values are replaced with `<redacted>`
  /// (case-insensitive).
  final Set<String> redactHeaders;

  /// JSON body keys whose values are replaced with `<redacted>`
  /// (case- and separator-insensitive).
  final Set<String> redactBodyKeys;

  /// Whether to log request bodies.
  final bool requestBody;

  /// Whether to log response bodies.
  final bool responseBody;

  /// Whether to wrap output in ANSI color codes.
  final bool useColors;

  static const _reset = '\u001B[0m';
  static const _cyan = '\u001B[36m';
  static const _green = '\u001B[32m';
  static const _red = '\u001B[31m';
  static const _grey = '\u001B[90m';

  late final Set<String> _normalizedRedactBodyKeys = {
    for (final key in redactBodyKeys) normalizeBodyKey(key),
  };

  /// Header names are matched case-insensitively. A caller that passes
  /// `{'Authorization'}` (mixed case) must still get redaction — otherwise the
  /// secret leaks into logs. Normalize the set once instead of trusting the
  /// caller to lowercase it.
  late final Set<String> _normalizedRedactHeaders = {
    for (final name in redactHeaders) name.toLowerCase(),
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
      _normalizedRedactHeaders.contains(name.toLowerCase())
          ? '<redacted>'
          : value;

  /// Redacts values for keys in [redactBodyKeys] from a JSON body string.
  /// Returns the original [body] if it isn't valid JSON.
  String _redactJsonBody(String body) {
    if (_normalizedRedactBodyKeys.isEmpty) return body;
    return redactJsonBody(body, _normalizedRedactBodyKeys);
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
