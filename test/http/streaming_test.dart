import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// A client whose response body is fed manually via a [StreamController], and
/// which counts close() calls. Lets us drive the streaming adapter precisely.
class _ManualClient extends http.BaseClient {
  _ManualClient();

  final int statusCode = 200;
  // Deliberately not auto-closed: several tests assert behavior when the body
  // stays open (cancel/abort paths), so closing is the test's choice.
  // ignore: close_sinks
  final body = StreamController<List<int>>();
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      body.stream,
      statusCode,
      headers: const {'content-type': 'application/octet-stream'},
    );
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

/// Minimal stand-in so we don't import dart:io just for an error type.
class SocketException implements Exception {
  const SocketException(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}

/// Returns headers/status immediately, then errors partway through the body —
/// models a connection reset mid-download.
class _BodyErrorClient extends http.BaseClient {
  _BodyErrorClient(this.status, this.chunks, this.error);
  final int status;
  final List<List<int>> chunks;
  final Object error;
  int closeCalls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    () async {
      for (final c in chunks) {
        controller.add(c);
        await Future<void>.delayed(Duration.zero);
      }
      controller.addError(error);
      await controller.close();
    }();
    return http.StreamedResponse(controller.stream, status,
        headers: const {'content-type': 'application/json'});
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

/// Returns a fixed status + raw body bytes + headers. The Swiss-army client for
/// decode-edge scenarios (malformed JSON, wrong content-type, empty body, ...).
class _FixedClient extends http.BaseClient {
  _FixedClient(this.status, this.body, {this.headers = const {}});
  final int status;
  final List<int> body;
  final Map<String, String> headers;
  int closeCalls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      status,
      headers: headers,
    );
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

/// Feeds the body manually via a controller. Lets a test stall mid-stream.
class _ManualBodyClient extends http.BaseClient {
  _ManualBodyClient();
  final int status = 200;
  // ignore: close_sinks
  final body = StreamController<List<int>>();
  int closeCalls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(body.stream, status,
        headers: const {'content-type': 'application/octet-stream'});
  }

  @override
  void close() {
    closeCalls++;
    // Faithfully model package:http: closing the client tears down any
    // in-flight body. Without this, a buffered send() awaiting the next chunk
    // would park forever when the transport "closes" — which is exactly the
    // hang the cancel path is meant to prevent.
    if (!body.isClosed) body.close();
    super.close();
  }
}

ApiClient _clientFor(http.BaseClient c, {int? maxResp, int? maxReq}) {
  return ApiClient(
    ApiClientConfig.test(
      baseUrl: 'https://api.example.com',
      adapter: DefaultHttpAdapter(clientFactory: () => c),
      maxResponseBodyBytes: maxResp,
      maxRequestBodyBytes: maxReq,
    ),
  );
}

/// Minimal exception standing in for a socket-level failure without importing
/// dart:io (which Flutter test discourages for pure-Dart adapter tests).
class _Sock implements Exception {
  const _Sock(this.message);
  final String message;
  @override
  String toString() => '_Sock: $message';
}

void main() {
  group('sendStreaming lifecycle', () {
    test('owned client closed exactly once after the body completes', () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/stream'),
          headers: const {},
          timeout: const Duration(seconds: 5),
        ),
      );

      final collected = <int>[];
      final done = Completer<void>();
      res.bodyStream!.listen(
        collected.addAll,
        onDone: done.complete,
        onError: done.completeError,
      );

      // Feed two chunks then end the body.
      client.body.add(utf8.encode('hello '));
      client.body.add(utf8.encode('world'));
      await client.body.close();

      await done.future;
      // Give the controller.done -> cleanup() microtask a chance to run.
      await Future<void>.delayed(Duration.zero);

      expect(utf8.decode(collected), 'hello world');
      expect(client.closeCalls, 1,
          reason: 'owned client must be closed exactly once on normal done');
    });

    test('cancel mid-stream surfaces CancelError, closes client once, no leak',
        () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);
      final token = CancelToken();

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/stream'),
          headers: const {},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        ),
      );

      Object? error;
      final chunks = <String>[];
      final done = Completer<void>();
      res.bodyStream!.listen(
        (c) => chunks.add(utf8.decode(c)),
        onError: (Object e) {
          error = e;
        },
        onDone: done.complete,
        cancelOnError: false,
      );

      // First chunk flows, then cancel before more arrives.
      client.body.add(utf8.encode('partial'));
      await Future<void>.delayed(Duration.zero);
      token.cancel('user abort');
      // After cancel, push another chunk; it must NOT be delivered.
      client.body.add(utf8.encode('more'));

      await done.future;
      await Future<void>.delayed(Duration.zero);

      expect(error, isA<CancelError>());
      expect(chunks, ['partial'],
          reason: 'a chunk arriving after cancel must not be delivered');
      expect(client.closeCalls, 1,
          reason: 'cancel must trigger exactly one owned-client close');
    });

    test('cancel before consumer subscribes still closes the owned client',
        () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);
      final token = CancelToken();

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/stream'),
          headers: const {},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        ),
      );

      // Cancel BEFORE anyone subscribes (upstream sub is paused).
      token.cancel('abort early');
      await Future<void>.delayed(Duration.zero);

      // Now subscribe; we must get the CancelError, and the client must close.
      Object? error;
      final done = Completer<void>();
      res.bodyStream!.listen(
        (_) {},
        onError: (Object e) => error = e,
        onDone: done.complete,
        cancelOnError: false,
      );

      await done.future;
      await Future<void>.delayed(Duration.zero);

      expect(error, isA<CancelError>());
      expect(client.closeCalls, 1);
    });

    test('response size guard aborts the stream and closes the client',
        () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/big'),
          headers: const {},
          timeout: const Duration(seconds: 5),
          maxResponseBodyBytes: 4,
        ),
      );

      Object? error;
      final done = Completer<void>();
      res.bodyStream!.listen(
        (_) {},
        onError: (Object e) => error = e,
        onDone: done.complete,
        cancelOnError: false,
      );

      client.body.add(utf8.encode('this exceeds four bytes'));
      await done.future;
      await Future<void>.delayed(Duration.zero);

      expect(error, isA<PayloadTooLargeError>());
      expect((error as PayloadTooLargeError).limitBytes, 4);
      expect(client.closeCalls, 1);
    });

    test('upstream error propagates and closes the owned client', () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/err'),
          headers: const {},
          timeout: const Duration(seconds: 5),
        ),
      );

      Object? error;
      final done = Completer<void>();
      res.bodyStream!.listen(
        (_) {},
        onError: (Object e) => error = e,
        onDone: done.complete,
        cancelOnError: false,
      );

      client.body.add(utf8.encode('chunk'));
      client.body.addError(const SocketException('reset'));
      await done.future;
      await Future<void>.delayed(Duration.zero);

      expect(error, isA<SocketException>());
      expect(client.closeCalls, 1);
    });

    test('consumer cancel stops pulling upstream and closes the client',
        () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/stream'),
          headers: const {},
          timeout: const Duration(seconds: 5),
        ),
      );

      final sub = res.bodyStream!.listen((_) {});
      client.body.add(utf8.encode('x'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(client.closeCalls, 1,
          reason: 'consumer cancel must release the owned client');
    });

    test('shared client is never closed by streaming cancel', () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(client: client);
      addTearDown(client.close);
      final token = CancelToken();

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/stream'),
          headers: const {},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        ),
      );

      final done = Completer<void>();
      res.bodyStream!.listen(
        (_) {},
        onError: (_) {},
        onDone: done.complete,
        cancelOnError: false,
      );

      client.body.add(utf8.encode('data'));
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      client.body.add(utf8.encode('more'));
      await done.future;
      await Future<void>.delayed(Duration.zero);

      // tearDown will close it once; the adapter must not have closed it.
      expect(client.closeCalls, 0,
          reason: 'injected shared client must outlive a single request');
    });

    test('back-pressure: upstream stays paused until consumer subscribes',
        () async {
      final client = _ManualClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);

      final res = await adapter.sendStreaming(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/stream'),
          headers: const {},
          timeout: const Duration(seconds: 5),
        ),
      );

      var received = '';
      // Subscribe, immediately receive buffered data once resumed.
      final done = Completer<void>();
      client.body.add(utf8.encode('queued'));
      await Future<void>.delayed(Duration.zero);
      expect(client.body.hasListener, true,
          reason: 'the adapter is subscribed to the upstream body');
      expect(client.body.isPaused, true,
          reason: 'but must not pull it until the consumer subscribes');

      res.bodyStream!.listen(
        (c) => received += utf8.decode(c),
        onDone: done.complete,
      );
      await client.body.close();
      await done.future;
      await Future<void>.delayed(Duration.zero);

      expect(received, 'queued');
      expect(client.closeCalls, 1);
    });
  });

  // =========================================================================
  // STREAMING ADVERSITY. Backpressure, cancel, size-guard, and the
  // critical no-leak invariant: the owned client closes exactly once on EVERY
  // exit path.
  // =========================================================================
  group('streaming transport adversity', () {
    test(
        'stream() size guard aborts and surfaces PayloadTooLargeError to consumer',
        () async {
      final c = _ManualBodyClient();
      final api = _clientFor(c, maxResp: 4);
      final res = await api.stream('s');
      expect(res.isSuccess, true, reason: 'headers arrive before the overflow');
      final stream = res.data!.stream;
      Object? err;
      final done = Completer<void>();
      stream.listen((_) {},
          onError: (Object e) => err = e,
          onDone: done.complete,
          cancelOnError: false);
      c.body.add(utf8.encode('overflowing chunk'));
      await done.future;
      await Future<void>.delayed(Duration.zero);
      expect(err, isA<PayloadTooLargeError>());
      expect(c.closeCalls, 1, reason: 'owned client closed once on size abort');
    });

    test('stream() consumer cancel mid-flight releases the owned client',
        () async {
      final c = _ManualBodyClient();
      final api = _clientFor(c);
      final res = await api.stream('s');
      final sub = res.data!.stream.listen((_) {});
      c.body.add(utf8.encode('chunk'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(c.closeCalls, 1);
    });

    test('stream() upstream reset mid-body propagates and closes client',
        () async {
      final c =
          _BodyErrorClient(200, [utf8.encode('chunk')], const _Sock('reset'));
      final api = _clientFor(c);
      final res = await api.stream('s');
      Object? err;
      final done = Completer<void>();
      res.data!.stream.listen((_) {},
          onError: (Object e) => err = e,
          onDone: done.complete,
          cancelOnError: false);
      await done.future;
      await Future<void>.delayed(Duration.zero);
      expect(err, isA<_Sock>());
      expect(c.closeCalls, 1);
    });

    test('HttpStreamResponse.toText decodes a chunked UTF-8 body', () async {
      final c = _ManualBodyClient();
      final api = _clientFor(c);
      final res = await api.stream('s');
      final fut = res.data!.toText();
      c.body.add(utf8.encode('hello '));
      c.body.add(utf8.encode('world'));
      await c.body.close();
      expect(await fut, 'hello world');
      await Future<void>.delayed(Duration.zero);
      expect(c.closeCalls, 1);
    });

    test('HttpStreamResponse.toBytes coalesces all chunks', () async {
      final c = _ManualBodyClient();
      final api = _clientFor(c);
      final res = await api.stream('s');
      final fut = res.data!.toBytes();
      c.body.add([1, 2, 3]);
      c.body.add([4, 5]);
      await c.body.close();
      expect(await fut, equals(Uint8List.fromList([1, 2, 3, 4, 5])));
    });

    test('stream() error status drains body so client never leaks', () async {
      final c = _FixedClient(500, utf8.encode('{"message":"boom"}'),
          headers: const {'content-type': 'application/json'});
      final api = _clientFor(c);
      final res = await api.stream('boom');
      expect(res.isFailure, true);
      expect(res.statusCode, 500);
      await Future<void>.delayed(Duration.zero);
      expect(c.closeCalls, 1,
          reason: 'unconsumed error stream is drained to drive cleanup');
    });
  });
}
