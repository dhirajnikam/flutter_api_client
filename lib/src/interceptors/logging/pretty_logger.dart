import 'dart:convert';

import '../../core/api_exception.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';

/// Pretty, line-broken request/response logger with optional ANSI colors
/// and header redaction.
class PrettyLogger extends Interceptor {
  PrettyLogger({
    this.printer = print,
    this.redactHeaders = const {'authorization', 'cookie', 'set-cookie'},
    this.requestBody = true,
    this.responseBody = true,
    this.useColors = true,
  });

  final void Function(String) printer;
  final Set<String> redactHeaders;
  final bool requestBody;
  final bool responseBody;
  final bool useColors;

  static const _reset = '\u001B[0m';
  static const _cyan = '\u001B[36m';
  static const _green = '\u001B[32m';
  static const _red = '\u001B[31m';
  static const _grey = '\u001B[90m';

  String _c(String code, String s) => useColors ? '$code$s$_reset' : s;

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    final buf = StringBuffer();
    buf.writeln(_c(_cyan, '┌─── ${req.method} ${req.endpoint} ───'));
    req.headers.forEach((k, v) {
      final value = redactHeaders.contains(k.toLowerCase()) ? '<redacted>' : v;
      buf.writeln(_c(_grey, '│ $k: $value'));
    });
    if (requestBody && req.data != null && !req.isMultipart) {
      final body = req.data is String ? req.data : jsonEncode(req.data);
      buf.writeln(_c(_grey, '│ body: $body'));
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
      buf.writeln(_c(_grey, '│ $k: $v'));
    });
    if (responseBody) {
      try {
        final body = utf8.decode(res.bodyBytes);
        if (body.isNotEmpty) {
          final preview = body.length > 2000
              ? '${body.substring(0, 2000)}…'
              : body;
          buf.writeln(_c(_grey, '│ body: $preview'));
        }
      } catch (_) {}
    }
    buf.writeln(_c(color, '└───────────────'));
    printer(buf.toString());
    return ResolveResult(res);
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
