import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/query.dart';
import 'interceptor.dart';
import 'internal_headers.dart';

/// Stable identity key for a request, used to match cache entries and to
/// coalesce duplicate in-flight requests.
///
/// Built from the method, the fully-resolved URL (base + endpoint + query),
/// and the request headers sorted by name. `If-None-Match` is excluded so
/// that a conditional revalidation request keys to the same entry as the
/// original; internal `x-fac-*` headers are excluded because they never reach
/// the origin.
///
/// The credential header is deliberately part of the key (as a digest, never
/// the token itself): cached bodies must never leak across credentials, so a
/// token refresh cold-starts the cache and stops dedup coalescing across the
/// refresh boundary. That re-fetch cost is the accepted price of credential
/// isolation.
String requestIdentityKey(InterceptedRequest req) {
  final url = buildUri(
    baseUrl: req.options.baseUrlOverride ?? '',
    endpoint: req.endpoint,
    queryParameters: req.options.queryParameters,
  ).toString();

  final entries = <_HeaderLine>[];
  for (final entry in req.headers.entries) {
    final lower = entry.key.toLowerCase();
    if (lower == 'if-none-match' || isInternalHeader(lower)) continue;
    // The credential still separates cache entries per user, but only its
    // digest is kept: keys are persisted by durable stores.
    final value = isCredentialHeader(req, lower)
        ? 'sha256:${sha256.convert(utf8.encode(entry.value))}'
        : entry.value;
    entries.add(_HeaderLine(lower, value));
  }

  final prefix = '${req.method.toUpperCase()} $url';
  if (entries.isEmpty) return prefix;

  entries.sort((a, b) => a.lowerKey.compareTo(b.lowerKey));

  final buffer = StringBuffer(prefix);
  for (final entry in entries) {
    buffer
      ..write('\n')
      ..write(entry.lowerKey)
      ..write(':')
      ..write(entry.value);
  }
  return buffer.toString();
}

class _HeaderLine {
  _HeaderLine(this.lowerKey, this.value);

  final String lowerKey;
  final String value;
}
