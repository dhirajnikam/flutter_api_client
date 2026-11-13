/// Case-insensitive lookup of [name] in [headers]. HTTP header names are
/// case-insensitive (RFC 7230 §3.2) and adapters are not required to
/// normalize them, so header reads must not assume a particular casing.
String? headerValue(Map<String, String> headers, String name) {
  final direct = headers[name];
  if (direct != null) return direct;
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}
