import 'dart:convert';
import 'dart:typed_data';

/// A streaming HTTP response whose body is delivered incrementally as bytes.
///
/// Returned by `ApiClient.stream`. Use it for large downloads or
/// SSE/NDJSON processing where buffering the entire body in memory is
/// undesirable. The [stream] is single-subscription — consume it once.
class HttpStreamResponse {
  HttpStreamResponse({
    required this.statusCode,
    required this.headers,
    required this.stream,
  });

  final int statusCode;
  final Map<String, String> headers;

  /// The live response body. Subscribe once.
  final Stream<List<int>> stream;

  /// Collects the full body into bytes. Consumes [stream].
  Future<Uint8List> toBytes() async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Decodes the full body as a UTF-8 string. Consumes [stream].
  Future<String> toText() => stream.transform(utf8.decoder).join();
}
