/// Shared sensitive-data redaction used by the logging interceptors.
///
/// Both `PrettyLogger` and `CurlLogger` strip secret-looking values out of
/// JSON request/response bodies before printing them. Matching is done on a
/// normalized form of each key (letters lowercased, non-alphanumeric stripped)
/// so `apiKey`, `api_key` and `API-KEY` all collapse to the same token.
library;

import 'dart:convert';

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
