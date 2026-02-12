import 'dart:convert';

import 'package:http/http.dart' as http;

import 'response_handler_interface.dart';

class ResponseHandler implements ResponseHandlerInterface {
  @override
  String? handleResponse(http.Response res) {
    try {
      final responseBody = utf8.decode(res.bodyBytes);

      if (responseBody.trim().isEmpty) {
        if (res.statusCode >= 200 && res.statusCode < 300) return null;
        return 'Server returned an empty response';
      }

      if (isHtmlOrTextResponse(responseBody)) {
        return 'The server returned an invalid response. Please try again later.';
      }

      try {
        final Map<String, dynamic> response = jsonDecode(responseBody);
        if (res.statusCode >= 200 && res.statusCode < 300) return null;
        final String errorMessage = getErrorMessage(response['message']);
        return errorMessage.isNotEmpty
            ? errorMessage
            : 'An unexpected error occurred.';
      } on FormatException {
        if (res.statusCode >= 200 && res.statusCode < 300) return null;
        return 'Failed to parse the response. Please try again later.';
      }
    } catch (e) {
      return 'Failed to process the response. Please check your connection and try again.';
    }
  }

  String getErrorMessage(dynamic error) {
    if (error == null) {
      return 'An unknown error occurred.';
    }
    if (error is String) {
      return error.isNotEmpty ? error : 'An unknown error occurred.';
    }
    if (error is List) {
      return error.join(', ');
    }
    if (error is Map<String, dynamic>) {
      String errorMessage = '';
      error.forEach((key, value) {
        if (value is List) {
          errorMessage += '$key: ${value.join(', ')}\n';
        } else if (value is String) {
          errorMessage += '$value\n';
        } else if (value is Map<String, dynamic>) {
          errorMessage += '$key: ${value.toString()}\n';
        }
      });
      return errorMessage.trim().isNotEmpty
          ? errorMessage.trim()
          : 'An unexpected error occurred.';
    }
    return error.toString();
  }

  @override
  bool isHtmlOrTextResponse(String responseBody) {
    final t = responseBody.trim();
    if (t.startsWith('<!DOCTYPE html>') ||
        t.startsWith('<html') ||
        (t.contains('<head>') && t.contains('<body>'))) {
      return true;
    }
    if (t.isEmpty) {
      return false;
    }
    if (t.length < 5 && !t.startsWith('{') && !t.startsWith('[')) {
      return true;
    }
    return false;
  }
}
