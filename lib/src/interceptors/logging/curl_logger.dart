import 'dart:convert';

import '../../core/query.dart';
import '../interceptor.dart';

/// Logs each request as a ready-to-paste cURL command.
class CurlLogger extends Interceptor {
  CurlLogger({
    this.printer = print,
    this.redactHeaders = const {'authorization'},
  });

  final void Function(String) printer;
  final Set<String> redactHeaders;

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    printer(_toCurl(req));
    return ProceedResult(req);
  }

  String _toCurl(InterceptedRequest req) {
    final buf = StringBuffer('curl -X ${req.method}');
    req.headers.forEach((k, v) {
      final value = redactHeaders.contains(k.toLowerCase()) ? '<redacted>' : v;
      buf.write(" -H '${k.replaceAll("'", r"\'")}: $value'");
    });
    if (req.data != null && !req.isMultipart) {
      final body = req.data is String ? req.data : jsonEncode(req.data);
      buf.write(" --data '${body.toString().replaceAll("'", r"\'")}'");
    }
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? '',
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    ).toString();
    buf.write(" '$url'");
    return buf.toString();
  }
}
