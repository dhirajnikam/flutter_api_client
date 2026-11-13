/// Shared sensitive-data redaction used by the logging interceptors.
///
/// Both `PrettyLogger` and `CurlLogger` strip secret-looking values out of
/// JSON request/response bodies before printing them. Matching is done on a
/// normalized form of each key (letters lowercased, non-alphanumeric stripped)
/// so `apiKey`, `api_key` and `API-KEY` all collapse to the same token.
library;

import 'dart:convert';

import '../interceptor.dart';
import '../internal_headers.dart';

/// Normalizes a body key for redaction matching: keeps ASCII letters and
/// digits, lowercases letters, and drops everything else (`-`, `_`, spaces…).
String normalizeBodyKey(String key) {
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

/// Recursively replaces values whose key normalizes to a member of
/// [normalizedRedactKeys] with `<redacted>`. Lists are walked element-wise;
/// scalars pass through unchanged.
dynamic redactJsonValue(dynamic value, Set<String> normalizedRedactKeys) {
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      result[key] = normalizedRedactKeys.contains(normalizeBodyKey(key))
          ? '<redacted>'
          : redactJsonValue(entry.value, normalizedRedactKeys);
    }
    return result;
  }
  if (value is List) {
    return value
        .map((e) => redactJsonValue(e, normalizedRedactKeys))
        .toList(growable: false);
  }
  return value;
}

/// Parses [body] as JSON, redacts it with [redactJsonValue], and re-encodes.
/// Returns [body] unchanged if it is not valid JSON.
String redactJsonBody(String body, Set<String> normalizedRedactKeys) {
  try {
    final decoded = jsonDecode(body);
    return jsonEncode(redactJsonValue(decoded, normalizedRedactKeys));
  } catch (_) {
    return body;
  }
}

/// Header names the loggers redact unless told otherwise.
const Set<String> defaultRedactHeaders = {
  'authorization',
  'cookie',
  'set-cookie',
  'proxy-authorization',
  'x-api-key',
  'x-auth-token',
};

/// JSON body keys the loggers redact unless told otherwise.
const Set<String> defaultRedactBodyKeys = {
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
};

/// Replaces secrets in what a logger is about to print.
class Redactor {
  /// [headers] are matched case-insensitively, [bodyKeys] case- and
  /// separator-insensitively, so callers need not normalize either set.
  Redactor({required Set<String> headers, required Set<String> bodyKeys})
      : _headers = {for (final name in headers) name.toLowerCase()},
        _bodyKeys = {for (final key in bodyKeys) normalizeBodyKey(key)};

  final Set<String> _headers;
  final Set<String> _bodyKeys;

  /// The value to print for header [name].
  String header(String name, String value) =>
      _headers.contains(name.toLowerCase()) ? '<redacted>' : value;

  /// The value to print for header [name] of [req]; also hides the header the
  /// auth interceptor wrote the token to.
  String requestHeader(InterceptedRequest req, String name, String value) =>
      isCredentialHeader(req, name) ? '<redacted>' : header(name, value);

  /// [body] with secret values replaced; unchanged if it is not JSON.
  String jsonBody(String body) =>
      _bodyKeys.isEmpty ? body : redactJsonBody(body, _bodyKeys);

  /// The redacted text to print for request payload [data].
  String requestBody(Object data) =>
      jsonBody(data is String ? data : jsonEncode(data));
}
