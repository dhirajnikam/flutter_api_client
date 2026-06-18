import 'dart:convert';

import '../../core/query.dart';
import '../interceptor.dart';

/// Logs each request as a ready-to-paste cURL command.
class CurlLogger extends Interceptor {
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

  final void Function(String) printer;
  final Set<String> redactHeaders;
  final Set<String> redactBodyKeys;

  late final Set<String> _normalizedRedactBodyKeys = {
    for (final key in redactBodyKeys) _normalizeKey(key),
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
      buf.write(" -H '${k.replaceAll("'", r"\'")}: $value'");
    });
    if (req.data != null && !req.isMultipart) {
      final body =
          req.data is String ? req.data as String : jsonEncode(req.data);
      final redacted = _redactJsonBody(body);
      buf.write(" --data '${redacted.replaceAll("'", r"\'")}'");
    }
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? '',
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    ).toString();
    buf.write(" '$url'");
    return buf.toString();
  }

  String _redactJsonBody(String body) {
    try {
      final decoded = jsonDecode(body);
      return jsonEncode(_redactValue(decoded));
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
}
