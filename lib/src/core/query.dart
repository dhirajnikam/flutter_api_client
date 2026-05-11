/// Builds a query string from a map.
///
/// Supports primitive values, `List` (repeated key) and nested `Map`
/// (bracketed key, e.g. `filter[name]=foo`).
String buildQueryString(Map<String, dynamic> params) {
  if (params.isEmpty) return '';
  final pairs = <String>[];
  void add(String key, dynamic value) {
    if (value == null) return;
    if (value is List) {
      for (final v in value) {
        add(key, v);
      }
      return;
    }
    if (value is Map) {
      value.forEach((k, v) => add('$key[$k]', v));
      return;
    }
    pairs.add(
      '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent('$value')}',
    );
  }

  params.forEach(add);
  return pairs.join('&');
}

/// Joins a base URL, endpoint and optional query parameters into a [Uri].
Uri buildUri({
  required String baseUrl,
  required String endpoint,
  Map<String, dynamic>? queryParameters,
}) {
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final ep = endpoint.startsWith('/') ? endpoint.substring(1) : endpoint;
  final qs = queryParameters == null ? '' : buildQueryString(queryParameters);
  final hasQ = ep.contains('?');
  final url = qs.isEmpty ? '$base/$ep' : '$base/$ep${hasQ ? '&' : '?'}$qs';
  return Uri.parse(url);
}
