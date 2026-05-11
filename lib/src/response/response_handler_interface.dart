import '../http/http_adapter.dart';

/// Pluggable response error message extractor.
abstract class ResponseHandlerInterface {
  /// Returns an error message for non-2xx responses, null otherwise.
  String? handleResponse(AdapterResponse response);

  /// True if the body looks like HTML/plain text instead of JSON.
  bool isHtmlOrTextResponse(String responseBody);
}
