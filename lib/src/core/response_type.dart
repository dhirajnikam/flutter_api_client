/// Desired shape of the parsed response body.
enum ResponseType {
  /// Decode body as JSON. Default.
  json,

  /// Return body as `Uint8List` bytes.
  bytes,

  /// Return body as a `String` without JSON decoding.
  plainText,

  /// Return the raw streamed response (advanced use).
  stream,
}
