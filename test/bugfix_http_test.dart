import 'dart:async';
import 'dart:convert';

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
  int sendCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCalls++;
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

void main() {
  group('sendStreaming lifecycle (w2 bugfixes)', () {
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
      final done = Completer<void>();
      res.bodyStream!.listen(
        (_) {},
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

  // ---------------------------------------------------------------------------
  // BUG (w1 / margaret-hamilton): ApiClient.stream() on a non-2xx response
  // returned a Failure and DISCARDED the unbuffered bodyStream without draining
  // it. The streaming adapter only closes its owned http.Client once
  // controller.done fires (on consume/cancel), so an unconsumed error-response
  // stream leaked the client forever. stream() must drain the body on the error
  // path to drive cleanup.
  // ---------------------------------------------------------------------------
  group('stream() error-response client lifecycle (w1 bugfix)', () {
    test('non-2xx streaming response drains body and closes owned client',
        () async {
      final client = _StatusClient(500, utf8.encode('{"error":"boom"}'));
      final adapter = DefaultHttpAdapter(clientFactory: () => client);
      final api = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: adapter,
        ),
      );

      final res = await api.stream('boom');
      expect(res.isFailure, true);
      expect(res.statusCode, 500);

      // Cleanup runs via controller.done after the drain; give the microtask a
      // chance to settle.
      await Future<void>.delayed(Duration.zero);
      expect(client.closeCalls, 1,
          reason:
              'owned client must close even when the body is never consumed');
    });
  });

  group('buffered send payload guard (w2 bugfixes)', () {
    test('response over limit closes the owned client exactly once', () async {
      final client = _ChunkClient([
        utf8.encode('aaaa'),
        utf8.encode('bbbb'),
      ]);
      final adapter = DefaultHttpAdapter(clientFactory: () => client);

      await expectLater(
        adapter.send(
          AdapterRequest(
            method: 'GET',
            url: Uri.parse('https://example.com/big'),
            headers: const {},
            timeout: const Duration(seconds: 5),
            maxResponseBodyBytes: 4,
          ),
        ),
        throwsA(isA<PayloadTooLargeError>()),
      );
      // No double-close: finally closes once (the inline close was removed).
      expect(client.closeCalls, 1);
    });
  });
}

class _ChunkClient extends http.BaseClient {
  _ChunkClient(this._chunks);

  final List<List<int>> _chunks;
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(_chunks),
      200,
      headers: const {'content-type': 'application/octet-stream'},
    );
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

/// Streams a fixed status + body once, counting close() calls. Used to assert
/// the owned client is released on the error-response streaming path.
class _StatusClient extends http.BaseClient {
  _StatusClient(this.status, this.body);

  final int status;
  final List<int> body;
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([body]),
      status,
      headers: const {'content-type': 'application/json'},
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
