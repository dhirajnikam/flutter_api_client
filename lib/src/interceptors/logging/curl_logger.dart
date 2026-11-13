import '../../core/query.dart';
import '../interceptor.dart';
import 'redaction.dart';

/// Logs each request as a ready-to-paste cURL command.
class CurlLogger extends Interceptor {
  CurlLogger({
    this.printer = print,
    this.redactHeaders = defaultRedactHeaders,
    this.redactBodyKeys = defaultRedactBodyKeys,
  });

  /// Sink each curl command is written to. Defaults to `print`.
  final void Function(String) printer;

  /// Header names whose values are replaced with `<redacted>`
  /// (case-insensitive).
  final Set<String> redactHeaders;

  /// JSON body keys whose values are replaced with `<redacted>`
  /// (case- and separator-insensitive).
  final Set<String> redactBodyKeys;

  late final _redactor =
      Redactor(headers: redactHeaders, bodyKeys: redactBodyKeys);

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    printer(_toCurl(req));
    return ProceedResult(req);
  }

  String _toCurl(InterceptedRequest req) {
    final buf = StringBuffer('curl -X ${req.method}');
    req.headers.forEach((k, v) {
      buf.write(
          " -H '${_shellQuote('$k: ${_redactor.requestHeader(req, k, v)}')}'");
    });
    if (req.data != null && !req.isMultipart) {
      final body = _redactor.requestBody(req.data as Object);
      buf.write(" --data '${_shellQuote(body)}'");
    }
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? '',
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    ).toString();
    buf.write(" '${_shellQuote(url)}'");
    return buf.toString();
  }

  /// Escapes [s] for embedding inside a single-quoted POSIX shell string.
  /// A literal `'` cannot be backslash-escaped inside single quotes; the
  /// portable idiom closes the quote, emits an escaped quote, then reopens:
  /// `'\''`.
  static String _shellQuote(String s) => s.replaceAll("'", "'\\''");
}
