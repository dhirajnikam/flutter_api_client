import '../core/query.dart';
import 'interceptor.dart';

const Set<String> _internalRequestHeaders = {
  'x-fac-cache-revalidate',
  'x-fac-dedup-key',
  'x-fac-retried-auth',
  'x-fac-retry-attempt',
};

bool isInternalRequestHeader(String name) =>
    _internalRequestHeaders.contains(name.toLowerCase());

Map<String, String> stripInternalRequestHeaders(Map<String, String> headers) {
  final out = <String, String>{};
  for (final entry in headers.entries) {
    if (isInternalRequestHeader(entry.key)) continue;
    out[entry.key] = entry.value;
  }
  return out;
}

String requestIdentityKey(InterceptedRequest req) {
  final url = buildUri(
    baseUrl: req.options.baseUrlOverride ?? '',
    endpoint: req.endpoint,
    queryParameters: req.options.queryParameters,
  ).toString();

  final entries = req.headers.entries.where((entry) {
    final name = entry.key.toLowerCase();
    return name != 'if-none-match' && !isInternalRequestHeader(name);
  }).toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

  if (entries.isEmpty) return '${req.method.toUpperCase()} $url';

  final buffer = StringBuffer('${req.method.toUpperCase()} $url');
  for (final entry in entries) {
    buffer
      ..write('\n')
      ..write(entry.key.toLowerCase())
      ..write(':')
      ..write(entry.value);
  }
  return buffer.toString();
}
