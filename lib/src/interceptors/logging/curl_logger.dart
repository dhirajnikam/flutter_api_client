import 'dart:convert';

import '../../core/query.dart';
import '../interceptor.dart';
import 'redaction.dart';

/// Logs each request as a ready-to-paste cURL command.
class CurlLogger extends Interceptor {
  /// Creates a curl logger with sensible secret-redaction defaults.
  CurlLogger({
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
  });

  /// Sink each curl command is written to. Defaults to `print`.
  final void Function(String) printer;

  /// Header names whose values are replaced with `<redacted>`
  /// (case-insensitive).
  final Set<String> redactHeaders;

  /// JSON body keys whose values are replaced with `<redacted>`
  /// (case- and separator-insensitive).
  final Set<String> redactBodyKeys;

  late final Set<String> _normalizedRedactBodyKeys = {
    for (final key in redactBodyKeys) normalizeBodyKey(key),
  };

  /// Case-insensitive header redaction set (see [PrettyLogger]). A mixed-case
  /// caller-supplied name must still be redacted in the emitted curl command.
  late final Set<String> _normalizedRedactHeaders = {
    for (final name in redactHeaders) name.toLowerCase(),
  };

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    printer(_toCurl(req));
    return ProceedResult(req);
  }

  String _toCurl(InterceptedRequest req) {
    final buf = StringBuffer('curl -X ${req.method}');
    req.headers.forEach((k, v) {
      final value =
          _normalizedRedactHeaders.contains(k.toLowerCase()) ? '<redacted>' : v;
      buf.write(" -H '${_shellQuote('$k: $value')}'");
    });
    if (req.data != null && !req.isMultipart) {
      final body =
          req.data is String ? req.data as String : jsonEncode(req.data);
      final redacted = redactJsonBody(body, _normalizedRedactBodyKeys);
      buf.write(" --data '${_shellQuote(redacted)}'");
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
  /// `'\''`. The previous `\'` produced a broken, non-pasteable command.
  static String _shellQuote(String s) => s.replaceAll("'", "'\\''");
}
