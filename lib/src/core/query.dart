/// How a `List` value is expanded into query-string pairs.
enum QueryListFormat {
  /// Repeat the key for each element: `tags=a&tags=b` (default, pre-1.3.0).
  repeated,

  /// Append `[]` to the key: `tags[]=a&tags[]=b`.
  brackets,

  /// Join the elements with commas into a single pair: `tags=a,b`.
  comma,
}

/// How a nested `Map` value is flattened into query-string keys.
enum QueryNestedStyle {
  /// Bracketed sub-keys: `filter[name]=foo` (default, pre-1.3.0).
  brackets,

  /// Dotted sub-keys: `filter.name=foo`.
  dotted,
}

/// Configurable serializer for URL query strings.
///
/// The default `const QueryEncoder()` reproduces the pre-1.3.0 behaviour
/// exactly: repeated-key lists, bracketed nested maps, dropped `null` values,
/// and `Uri.encodeQueryComponent` (which encodes spaces as `+`).
class QueryEncoder {
  /// Creates a query encoder. All knobs default to the pre-1.3.0 behaviour.
  const QueryEncoder({
    this.listFormat = QueryListFormat.repeated,
    this.nested = QueryNestedStyle.brackets,
    this.includeNulls = false,
    this.encodeComponent = Uri.encodeQueryComponent,
  });

  /// Controls how `List` values are expanded.
  final QueryListFormat listFormat;

  /// Controls how nested `Map` values are flattened.
  final QueryNestedStyle nested;

  /// When true, `null` values are emitted as an empty value (`key=`) instead
  /// of being dropped.
  final bool includeNulls;

  /// Percent-encodes a key or value. Defaults to [Uri.encodeQueryComponent].
  final String Function(String) encodeComponent;

  /// Serializes [params] into a query string (without a leading `?`).
  ///
  /// Supports primitive values, `List` (per [listFormat]) and nested `Map`
  /// (per [nested]).
  String encode(Map<String, dynamic> params) {
    if (params.isEmpty) return '';
    final pairs = <String>[];
    void add(String key, dynamic value) {
      if (value == null) {
        if (includeNulls) pairs.add('${encodeComponent(key)}=');
        return;
      }
      if (value is List) {
        switch (listFormat) {
          case QueryListFormat.repeated:
            for (final v in value) {
              add(key, v);
            }
          case QueryListFormat.brackets:
            for (final v in value) {
              add('$key[]', v);
            }
          case QueryListFormat.comma:
            // Encode each element, then join with a literal comma so the
            // separator survives on the wire as `key=v1,v2,v3` (the point of
            // the comma format). A custom [encodeComponent] still governs how
            // each element is escaped.
            final rendered = value
                .where((v) => v != null)
                .map((v) => encodeComponent('$v'))
                .join(',');
            pairs.add('${encodeComponent(key)}=$rendered');
        }
        return;
      }
      if (value is Map) {
        value.forEach((k, v) {
          final childKey = switch (nested) {
            QueryNestedStyle.brackets => '$key[$k]',
            QueryNestedStyle.dotted => '$key.$k',
          };
          add(childKey, v);
        });
        return;
      }
      pairs.add('${encodeComponent(key)}=${encodeComponent('$value')}');
    }

    params.forEach(add);
    return pairs.join('&');
  }
}

/// Builds a query string from a map.
///
/// Supports primitive values, `List` (repeated key) and nested `Map`
/// (bracketed key, e.g. `filter[name]=foo`). Pass [encoder] to customize the
/// list/nested/null-handling behaviour; omit it for the default behaviour.
String buildQueryString(
  Map<String, dynamic> params, [
  QueryEncoder encoder = const QueryEncoder(),
]) =>
    encoder.encode(params);

/// Joins a base URL, endpoint and optional query parameters into a [Uri].
///
/// Pass [encoder] to control how [queryParameters] are serialized; omit it for
/// the default behaviour.
Uri buildUri({
  required String baseUrl,
  required String endpoint,
  Map<String, dynamic>? queryParameters,
  QueryEncoder encoder = const QueryEncoder(),
}) {
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final ep = endpoint.startsWith('/') ? endpoint.substring(1) : endpoint;
  final qs =
      queryParameters == null ? '' : encoder.encode(queryParameters);
  if (qs.isEmpty) return Uri.parse('$base/$ep');

  // Choose the correct separator when merging `qs` onto an endpoint that may
  // already carry a query string:
  //   - no '?'        -> start a query with '?'
  //   - '?' with body -> append with '&'
  //   - trailing '?'  -> empty existing query, append directly (no '&')
  final qIndex = ep.indexOf('?');
  final String separator;
  if (qIndex < 0) {
    separator = '?';
  } else if (qIndex == ep.length - 1) {
    separator = ''; // endpoint ends in a bare '?', e.g. "users?"
  } else {
    separator = '&';
  }
  return Uri.parse('$base/$ep$separator$qs');
}
