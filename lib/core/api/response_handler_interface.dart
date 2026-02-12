import 'package:http/http.dart' as http;

/// Interface for custom response handling.
///
/// Implement this to provide your own error parsing, message extraction,
/// or HTML detection logic.
abstract class ResponseHandlerInterface {
  /// Returns an error message if the response indicates failure, null otherwise.
  String? handleResponse(http.Response response);

  /// Returns true if the response body appears to be HTML or plain text (not JSON).
  bool isHtmlOrTextResponse(String responseBody);
}
