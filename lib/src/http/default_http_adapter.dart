import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/api_exception.dart';
import 'http_adapter.dart';

/// Default adapter built on `package:http`.
///
/// Each request gets a private [http.Client] so cancellation never affects
/// other in-flight requests.
class DefaultHttpAdapter implements HttpAdapter {
  DefaultHttpAdapter({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? (() => http.Client());

  final http.Client Function() _clientFactory;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    final client = _clientFactory();
    var cancelled = false;
    final removeListener = request.cancelToken?.addListener((err) {
      cancelled = true;
      client.close();
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

      _reportSendProgress(httpRequest, request.onSendProgress);

      final streamed = await client.send(httpRequest).timeout(request.timeout);

      final total = streamed.contentLength;
      var received = 0;
      final chunks = <List<int>>[];
      await for (final chunk in streamed.stream) {
        if (cancelled) {
          throw request.cancelToken?.error ?? const CancelError();
        }
        chunks.add(chunk);
        received += chunk.length;
        request.onReceiveProgress?.call(received, total);
      }
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
    } on CancelError {
      rethrow;
    } catch (e, st) {
      if (request.cancelToken?.isCancelled ?? false) {
        throw request.cancelToken!.error!;
      }
      throw NetworkError(e.toString(), cause: e, stackTrace: st);
    } finally {
      removeListener?.call();
      client.close();
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

  @override
  void close() {}
}

/// Encodes [data] to JSON bytes for non-multipart requests.
List<int>? encodeBody(dynamic data) {
  if (data == null) return null;
  if (data is String) return utf8.encode(data);
  if (data is List<int>) return data;
  return utf8.encode(jsonEncode(data));
}
