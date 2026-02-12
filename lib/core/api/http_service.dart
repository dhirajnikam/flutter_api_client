import 'dart:convert';

import 'package:http/http.dart' as http;

class CancellableRequest<T> {
  CancellableRequest(this._client, this.future);

  final http.Client _client;
  final Future<T> future;
  bool _isCancelled = false;

  void cancel() {
    if (!_isCancelled) {
      _client.close();
      _isCancelled = true;
    }
  }

  bool get isCancelled => _isCancelled;
}

class HttpService {
  HttpService(this.baseUrl);

  final String baseUrl;
  static final http.Client _client = http.Client();
  static const Duration requestTimeout = Duration(seconds: 30);

  CancellableRequest<http.Response> sendRequest(
    String method,
    String endpoint, {
    dynamic data,
    Map<String, String>? headers,
    bool isMultipart = false,
    Duration? timeout,
    String? baseUrlOverride,
  }) {
    final effectiveTimeout = timeout ?? requestTimeout;
    final effectiveBaseUrl = baseUrlOverride ?? baseUrl;
    final url = Uri.parse('$effectiveBaseUrl/$endpoint');
    Future<http.Response> future;

    if (isMultipart) {
      future = sendMultipartRequest(
        method,
        url,
        data: data,
        headers: headers,
        client: _client,
      ).timeout(effectiveTimeout);
    } else {
      switch (method.toUpperCase()) {
        case 'GET':
          future = _client.get(url, headers: headers).timeout(effectiveTimeout);
          break;
        case 'POST':
          future = _client
              .post(url, headers: headers, body: jsonEncode(data))
              .timeout(effectiveTimeout);
          break;
        case 'PATCH':
          future = _client
              .patch(url, headers: headers, body: jsonEncode(data))
              .timeout(effectiveTimeout);
          break;
        case 'PUT':
          future = _client
              .put(url, headers: headers, body: jsonEncode(data))
              .timeout(effectiveTimeout);
          break;
        case 'DELETE':
          future = _client
              .delete(url, headers: headers)
              .timeout(effectiveTimeout);
          break;
        default:
          throw UnsupportedError('HTTP method $method not supported');
      }
    }

    future = future.whenComplete(() {});
    return _CancellableRequestWithCallback(_client, future, () {});
  }

  Future<http.Response> sendMultipartRequest(
    String method,
    Uri url, {
    dynamic data,
    Map<String, String>? headers,
    http.Client? client,
  }) async {
    final effectiveClient = client ?? http.Client();
    final shouldCloseClient = client == null;
    try {
      var request = http.MultipartRequest(method, url);
      if (headers != null) {
        request.headers.addAll(headers);
      }
      if (data != null) {
        data.forEach((key, value) {
          if (value is List<http.MultipartFile>) {
            request.files.addAll(value);
          } else if (value is http.MultipartFile) {
            request.files.add(value);
          } else {
            request.fields[key] = value.toString();
          }
        });
      }
      var streamedResponse = await effectiveClient.send(request);
      return await http.Response.fromStream(streamedResponse);
    } finally {
      if (shouldCloseClient) effectiveClient.close();
    }
  }
}

class _CancellableRequestWithCallback<T> extends CancellableRequest<T> {
  _CancellableRequestWithCallback(super.client, super.future, this.onCancel);
  final void Function() onCancel;

  @override
  void cancel() {
    if (!isCancelled) {
      onCancel();
      super.cancel();
    }
  }
}
