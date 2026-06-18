import 'dart:convert';
import 'dart:typed_data';

import 'http_adapter.dart';

/// Builds a canned response for a matched request.
typedef MockResponder = Future<AdapterResponse> Function(AdapterRequest req);

/// Route matcher used by [MockAdapter].
class MockRoute {
  MockRoute({
    required this.method,
    required this.path,
    required this.responder,
  });

  /// HTTP method this route matches (case-insensitive).
  final String method;

  /// Pattern matched against the request URL path.
  final RegExp path;

  /// Produces the response when this route matches.
  final MockResponder responder;

  /// True if [req] matches this route's method and path.
  bool matches(AdapterRequest req) {
    if (req.method.toUpperCase() != method.toUpperCase()) return false;
    return path.hasMatch(req.url.path);
  }
}

/// HTTP adapter that returns canned responses, perfect for tests.
class MockAdapter implements HttpAdapter {
  MockAdapter({List<MockRoute>? routes, this.latency})
      : routes = routes ?? <MockRoute>[];

  /// Registered routes, tried in order on each request.
  final List<MockRoute> routes;

  /// Artificial delay applied to every response.
  final Duration? latency;

  /// Requests captured in order, useful for assertions.
  final List<AdapterRequest> received = [];

  /// Registers a route returning a fixed [statusCode] and [body].
  ///
  /// A `String` [pathPattern] matches the full path exactly; pass a [RegExp]
  /// for partial or pattern matching.
  void on(
    String method,
    Pattern pathPattern, {
    required int statusCode,
    Object? body,
    Map<String, String> headers = const {'content-type': 'application/json'},
    Duration? delay,
  }) {
    final pattern = pathPattern is RegExp
        ? pathPattern
        : RegExp('^${RegExp.escape(pathPattern.toString())}\$');
    routes.add(
      MockRoute(
        method: method,
        path: pattern,
        responder: (_) async {
          if (delay != null) await Future.delayed(delay);
          return AdapterResponse(
            statusCode: statusCode,
            headers: Map.of(headers),
            bodyBytes: _encode(body),
          );
        },
      ),
    );
  }

  /// Registers a route whose response is built dynamically by [responder].
  void onRequest(String method, Pattern pathPattern, MockResponder responder) {
    final pattern = pathPattern is RegExp
        ? pathPattern
        : RegExp('^${RegExp.escape(pathPattern.toString())}\$');
    routes.add(MockRoute(method: method, path: pattern, responder: responder));
  }

  @override
  Future<AdapterResponse> send(AdapterRequest req) async {
    received.add(req);
    if (latency != null) await Future.delayed(latency!);
    for (final r in routes) {
      if (r.matches(req)) return r.responder(req);
    }
    return AdapterResponse(
      statusCode: 404,
      headers: const {'content-type': 'application/json'},
      bodyBytes: _encode({
        'message': 'No mock route for ${req.method} ${req.url.path}',
      }),
    );
  }

  Uint8List _encode(Object? body) {
    if (body == null) return Uint8List(0);
    if (body is String) return Uint8List.fromList(utf8.encode(body));
    if (body is List<int>) return Uint8List.fromList(body);
    return Uint8List.fromList(utf8.encode(jsonEncode(body)));
  }

  @override
  void close() {}
}
