import 'dart:async';
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
class DefaultHttpAdapter implements HttpAdapter, StreamingHttpAdapter {
  DefaultHttpAdapter(
      {http.Client Function()? clientFactory, http.Client? client})
      : _clientFactory = clientFactory ?? (() => http.Client()),
        _sharedClient = client;

  final http.Client Function() _clientFactory;
  final http.Client? _sharedClient;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    final ownsClient = _sharedClient == null;
    final client = _sharedClient ?? _clientFactory();
    var cancelled = false;
    // Close the owned client exactly once: the cancel listener closes it to
    // interrupt an in-flight send/read promptly, and the `finally` closes it on
    // every other exit.
    var closed = false;
    void closeOwned() {
      if (closed || !ownsClient) return;
      closed = true;
      client.close();
    }

    final removeListener = request.cancelToken?.addListener((err) {
      cancelled = true;
      closeOwned();
    });

    try {
      final streamed = await _sendHeaders(client, request);

      final total = streamed.contentLength;
      var received = 0;
      final builder = BytesBuilder(copy: false);
      // `.timeout` on client.send only covers the headers; a body that stalls
      // mid-dribble would otherwise hang forever. Re-arm the same timeout per
      // chunk so a stalled body surfaces as a TimeoutError too (the await-for
      // cancels the subscription, and `finally` closes the owned client).
      final body = streamed.stream.timeout(request.timeout);
      await for (final chunk in body) {
        if (cancelled) {
          throw request.cancelToken?.error ?? const CancelError();
        }
        final nextReceived = received + chunk.length;
        final maxResponseBodyBytes = request.maxResponseBodyBytes;
        if (maxResponseBodyBytes != null &&
            nextReceived > maxResponseBodyBytes) {
          // The `finally` block closes the owned client; don't close it here
          // and double-close while the stream is still being torn down.
          throw _payloadTooLarge(
            direction: 'response',
            limitBytes: maxResponseBodyBytes,
            actualBytes: nextReceived,
          );
        }
        received = nextReceived;
        builder.add(chunk);
        request.onReceiveProgress?.call(received, total);
      }
      request.cancelToken?.throwIfCancelled();
      final bytes = builder.takeBytes();

      return AdapterResponse(
        statusCode: streamed.statusCode,
        headers: streamed.headers,
        bodyBytes: bytes,
        reasonPhrase: streamed.reasonPhrase,
      );
    } catch (e, st) {
      Error.throwWithStackTrace(_asApiException(e, st, request), st);
    } finally {
      removeListener?.call();
      closeOwned();
    }
  }

  @override
  Future<AdapterResponse> sendStreaming(AdapterRequest request) async {
    final ownsClient = _sharedClient == null;
    final client = _sharedClient ?? _clientFactory();
    var cancelled = false;
    // cleanup() can be reached from several paths (cancel listener, the
    // controller.done callback, and the synchronous catch blocks). Guard it so
    // the owned client is closed exactly once and the listener is removed once.
    var cleanedUp = false;
    void Function()? removeListener;
    void cleanup() {
      if (cleanedUp) return;
      cleanedUp = true;
      removeListener?.call();
      if (ownsClient) client.close();
    }

    // Bound once the controller exists; lets a cancel that arrives while the
    // upstream subscription is paused (consumer not pulling yet) still abort
    // deterministically instead of leaking the client until consumption.
    void Function(Object error)? abortRef;

    removeListener = request.cancelToken?.addListener((err) {
      cancelled = true;
      // Don't close the client here: the body may still be streaming to the
      // consumer. Closing is deferred to cleanup(), driven by controller.done.
      abortRef?.call(err);
    });

    try {
      final streamed = await _sendHeaders(client, request);

      final total = streamed.contentLength;
      final maxResponseBodyBytes = request.maxResponseBodyBytes;
      var received = 0;

      // Forward bytes through a controller so cancellation, the response-size
      // guard, and per-chunk progress all apply incrementally — without ever
      // buffering the whole body. The owned client is closed only once the
      // stream is fully consumed (or errors), not before.
      final controller = StreamController<List<int>>();
      late StreamSubscription<List<int>> sub;

      // Abort the upstream subscription, surface [error] to the consumer, and
      // close the controller so its `done` future fires and cleanup() runs.
      // Closing is essential: addError alone never completes controller.done,
      // which would leak the owned client and the cancel listener.
      void abort(Object error) {
        sub.cancel();
        if (!controller.isClosed) {
          controller
            ..addError(error)
            ..close();
        }
      }

      sub = streamed.stream.listen(
        (chunk) {
          if (cancelled) {
            abort(request.cancelToken?.error ?? const CancelError());
            return;
          }
          final next = received + chunk.length;
          if (maxResponseBodyBytes != null && next > maxResponseBodyBytes) {
            abort(
              _payloadTooLarge(
                direction: 'response',
                limitBytes: maxResponseBodyBytes,
                actualBytes: next,
              ),
            );
            return;
          }
          received = next;
          controller.add(chunk);
          request.onReceiveProgress?.call(received, total);
        },
        onError: (Object e, StackTrace st) {
          if (!controller.isClosed) {
            controller
              ..addError(e, st)
              ..close();
          }
        },
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
        cancelOnError: true,
      );
      // Propagate back-pressure: pause the upstream HTTP subscription whenever
      // the consumer pauses (or hasn't subscribed yet), so we don't buffer the
      // whole body in `controller` and defeat the point of streaming. Start
      // paused — the listen() above began pulling immediately.
      sub.pause();
      abortRef = abort;
      controller
        ..onListen = sub.resume
        ..onPause = sub.pause
        ..onResume = sub.resume
        // If the consumer cancels its subscription, stop pulling from upstream.
        // controller.done completes on cancel too, so cleanup() still runs.
        ..onCancel = () => sub.cancel();
      unawaited(controller.done.then((_) => cleanup()));

      return AdapterResponse(
        statusCode: streamed.statusCode,
        headers: streamed.headers,
        bodyBytes: Uint8List(0),
        reasonPhrase: streamed.reasonPhrase,
        bodyStream: controller.stream,
      );
    } catch (e, st) {
      cleanup();
      Error.throwWithStackTrace(_asApiException(e, st, request), st);
    }
  }

  /// Sends [request] and waits for the response headers; the body is still
  /// unread.
  Future<http.StreamedResponse> _sendHeaders(
    http.Client client,
    AdapterRequest request,
  ) async {
    final httpRequest = _buildHttpRequest(request);
    _checkRequestSize(httpRequest, request.maxRequestBodyBytes);
    _reportSendProgress(httpRequest, request.onSendProgress);
    request.cancelToken?.throwIfCancelled();
    final streamed = await client.send(httpRequest).timeout(request.timeout);
    request.cancelToken?.throwIfCancelled();
    return streamed;
  }

  ApiException _asApiException(
      Object e, StackTrace st, AdapterRequest request) {
    if (e is ApiException) return e;
    if (e is TimeoutException) {
      return TimeoutError(
        'Request timed out after ${request.timeout.inMilliseconds}ms',
        cause: e,
        stackTrace: st,
      );
    }
    final cancelError = request.cancelToken?.error;
    if (cancelError != null) return cancelError;
    // ponytail: connect-phase failures (DNS, refused) are not told apart from
    // mid-flight ones — package:http fuses connect, write and response.
    // `sent: false` is the extension point if that ever becomes detectable.
    return NetworkError(e.toString(), cause: e, stackTrace: st);
  }

  http.BaseRequest _buildHttpRequest(AdapterRequest request) {
    if (request.isMultipart) {
      final mp = http.MultipartRequest(request.method, request.url);
      mp.headers.addAll(_strippedHeaders(request.headers));
      final fd = request.formData;
      if (fd != null) {
        mp.fields.addAll(fd.fields);
        mp.files.addAll(fd.files);
      }
      return mp;
    }
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
    return r;
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
    throw _payloadTooLarge(
      direction: 'request',
      limitBytes: maxBytes,
      actualBytes: total,
    );
  }

  PayloadTooLargeError _payloadTooLarge({
    required String direction,
    required int limitBytes,
    required int actualBytes,
  }) =>
      PayloadTooLargeError(
        '$direction body exceeded configured limit of $limitBytes bytes',
        limitBytes: limitBytes,
        actualBytes: actualBytes,
        direction: direction,
      );

  @override
  void close() {
    _sharedClient?.close();
  }
}
