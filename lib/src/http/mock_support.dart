import 'dart:convert';
import 'dart:typed_data';

import 'http_adapter.dart';

/// Encodes a canned mock body: strings and byte lists pass through, anything
/// else is JSON-encoded.
Uint8List encodeMockBody(Object? body) {
  if (body == null) return Uint8List(0);
  if (body is String) return Uint8List.fromList(utf8.encode(body));
  if (body is List<int>) return Uint8List.fromList(body);
  return Uint8List.fromList(utf8.encode(jsonEncode(body)));
}

/// A response with a JSON content type carrying [body].
AdapterResponse jsonResponse(int statusCode, Object? body) => AdapterResponse(
      statusCode: statusCode,
      headers: const {'content-type': 'application/json'},
      bodyBytes: encodeMockBody(body),
    );

/// The JSON `404` a mock returns when it has no [what] matching [req].
AdapterResponse notFoundResponse(String what, AdapterRequest req) =>
    jsonResponse(404, {
      'message': 'No $what for ${req.method} ${req.url.path}',
    });
