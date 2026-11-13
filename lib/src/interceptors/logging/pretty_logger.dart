import '../../core/api_exception.dart';
import '../../core/serialization.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import 'redaction.dart';

/// Pretty, line-broken request/response logger with optional ANSI colors
/// and header redaction.
class PrettyLogger extends Interceptor {
  PrettyLogger({
    this.printer = print,
    this.redactHeaders = defaultRedactHeaders,
    this.redactBodyKeys = defaultRedactBodyKeys,
    this.requestBody = true,
    this.responseBody = true,
    this.useColors = true,
    this.charset = const Utf8Charset(),
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

  /// Charset used to decode response bodies for logging. Defaults to UTF-8;
  /// bodies that fail to decode are simply not logged.
  final Charset charset;

  static const _reset = '\u001B[0m';
  static const _cyan = '\u001B[36m';
  static const _green = '\u001B[32m';
  static const _red = '\u001B[31m';
  static const _grey = '\u001B[90m';

  late final _redactor =
      Redactor(headers: redactHeaders, bodyKeys: redactBodyKeys);

  String _c(String code, String s) => useColors ? '$code$s$_reset' : s;

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    final buf = StringBuffer();
    buf.writeln(_c(_cyan, '┌─── ${req.method} ${req.endpoint} ───'));
    req.headers.forEach((k, v) {
      buf.writeln(_c(_grey, '│ $k: ${_redactor.requestHeader(req, k, v)}'));
    });
    if (requestBody && req.data != null && !req.isMultipart) {
      final body = _redactor.requestBody(req.data as Object);
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
      buf.writeln(_c(_grey, '│ $k: ${_redactor.header(k, v)}'));
    });
    if (responseBody) {
      try {
        final body = charset.decode(res.bodyBytes);
        if (body.isNotEmpty) {
          // Redact first: a truncated JSON body no longer parses, and would be
          // printed with its secrets intact.
          final redacted = _redactor.jsonBody(body);
          final preview = redacted.length > 2000
              ? '${redacted.substring(0, 2000)}…'
              : redacted;
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
