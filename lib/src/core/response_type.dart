/// Desired shape of the parsed response body.
enum ResponseType {
  /// Decode body as JSON. Default.
  json,

  /// Return body as `Uint8List` bytes.
  bytes,

  /// Return body as a `String` without JSON decoding.
  plainText,

  /// Return the buffered body bytes.
  ///
  /// Note: the typed `get`/`post`/etc. path always buffers the body. For a
  /// genuinely unbuffered, incremental body use `ApiClient.stream`, which
  /// returns an `HttpStreamResponse`.
  @Deprecated(
    'Behaves exactly like bytes; use ResponseType.bytes, or '
    'ApiClient.stream for an unbuffered body. To be removed in '
    '2.0.0.',
  )
  stream,
}
