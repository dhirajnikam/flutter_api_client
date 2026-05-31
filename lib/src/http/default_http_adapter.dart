import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/api_exception.dart';
import 'http_adapter.dart';

/// Default adapter built on `package:http`.
///
/// By default each request gets a private [http.Client], so cancelling a
/// request can close that owned client without affecting unrelated requests.
/// If you inject a shared [client], cancellation still surfaces as
/// [CancelError] to the caller, but this adapter will not close the shared
/// client on behalf of one request.
class DefaultHttpAdapter implements HttpAdapter {
  DefaultHttpAdapter({http.Client Function()? clientFactory, http.Client? client})
      : _clientFactory = clientFactory ?? (() => http.Client()),
        _sharedClient = client;

  final http.Client Function() _clientFactory;
  final http.Client? _sharedClient;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    final ownsClient = _sharedClient == null;
    final client = _sharedClient ?? _clientFactory();
    var cancelled = false;
    final removeListener = request.cancelToken?.addListener((err) {
      cancelled = true;
      if (ownsClient) client.close();
    });

    try {
      http.BaseRequest httpRequest;
      if (request.isMultipart) {
        final mp = http.MultipartRequest(request.method, request.url);
        mp.headers.addAll(_strippedHeaders(request.headers));
        final fd = request.formData;
        if (fd != null) {
          mp.fields.addAll(fd.fields);
          mp.files.addAll(fd.files);
        }
        httpRequest = mp;
      } else {
        final r = http.Request(request.method, request.url);
        r.headers.addAll(request.headers);
        final body = request.body;
        if (body is String) {
          r.body = body;
        } else if (body is List<int>) {
          r.bodyBytes = body;
        } else if (body != null) {
          r.body = body.toString();
        }
        httpRequest = r;
      }

      _checkRequestSize(httpRequest, request.maxRequestBodyBytes);

      _reportSendProgress(httpRequest, request.onSendProgress);
      request.cancelToken?.throwIfCancelled();

      final streamed = await client.send(httpRequest).timeout(request.timeout);
      request.cancelToken?.throwIfCancelled();

      final total = streamed.contentLength;
      var received = 0;
      final chunks = <List<int>>[];
      await for (final chunk in streamed.stream) {
        if (cancelled) {
          throw request.cancelToken?.error ?? const CancelError();
        }
        final nextReceived = received + chunk.length;
        final maxResponseBodyBytes = request.maxResponseBodyBytes;
        if (maxResponseBodyBytes != null && nextReceived > maxResponseBodyBytes) {
          if (ownsClient) client.close();
          _throwPayloadTooLarge(
            direction: 'response',
            limitBytes: maxResponseBodyBytes,
            actualBytes: nextReceived,
          );
        }
        received = nextReceived;
        chunks.add(chunk);
        request.onReceiveProgress?.call(received, total);
      }
      request.cancelToken?.throwIfCancelled();
      final bytes = Uint8List.fromList(
        chunks.expand((c) => c).toList(growable: false),
      );

      return AdapterResponse(
        statusCode: streamed.statusCode,
        headers: streamed.headers,
        bodyBytes: bytes,
        reasonPhrase: streamed.reasonPhrase,
      );
    } on TimeoutException catch (e, st) {
      throw TimeoutError(
        'Request timed out after ${request.timeout.inMilliseconds}ms',
        cause: e,
        stackTrace: st,
      );
    } on ApiException {
      rethrow;
    } catch (e, st) {
      if (request.cancelToken?.isCancelled ?? false) {
        throw request.cancelToken!.error!;
      }
      throw NetworkError(e.toString(), cause: e, stackTrace: st);
    } finally {
      removeListener?.call();
      if (ownsClient) client.close();
    }
  }

  Map<String, String> _strippedHeaders(Map<String, String> headers) {
    final out = Map<String, String>.from(headers);
    out.removeWhere((k, _) => k.toLowerCase() == 'content-type');
    return out;
  }

  void _reportSendProgress(
    http.BaseRequest request,
    void Function(int, int?)? cb,
  ) {
    if (cb == null) return;
    final total = request.contentLength;
    if (total == null) return;
    cb(0, total);
    if (request is http.Request) {
      cb(request.bodyBytes.length, total);
    } else if (request is http.MultipartRequest) {
      cb(total, total);
    }
  }

  void _checkRequestSize(http.BaseRequest request, int? maxBytes) {
    if (maxBytes == null) return;
    final total = request.contentLength;
    if (total == null || total <= maxBytes) return;
    _throwPayloadTooLarge(
      direction: 'request',
      limitBytes: maxBytes,
      actualBytes: total,
    );
  }

  Never _throwPayloadTooLarge({
    required String direction,
    required int limitBytes,
    required int actualBytes,
  }) {
    throw PayloadTooLargeError(
      '$direction body exceeded configured limit of $limitBytes bytes',
      limitBytes: limitBytes,
      actualBytes: actualBytes,
      direction: direction,
    );
  }

  @override
  void close() {
    _sharedClient?.close();
  }
}

/// Encodes [data] to JSON bytes for non-multipart requests.
List<int>? encodeBody(dynamic data) {
  if (data == null) return null;
  if (data is String) return utf8.encode(data);
  if (data is List<int>) return data;
  return utf8.encode(jsonEncode(data));
}
