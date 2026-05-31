import '../core/query.dart';
import 'interceptor.dart';

String requestIdentityKey(InterceptedRequest req) {
  final url = buildUri(
    baseUrl: req.options.baseUrlOverride ?? '',
    endpoint: req.endpoint,
    queryParameters: req.options.queryParameters,
  ).toString();

  final entries = req.headers.entries.where((entry) {
    final name = entry.key.toLowerCase();
    return name != 'if-none-match' && !name.startsWith('x-fac-');
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
