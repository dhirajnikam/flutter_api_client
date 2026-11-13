import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _ProbeClient extends http.BaseClient {
  final _response = Completer<http.StreamedResponse>();
  final _controller = StreamController<List<int>>();
  int closeCalls = 0;

  void _ensureResponse() {
    if (_response.isCompleted) return;
    _response.complete(
      http.StreamedResponse(
        _controller.stream,
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
  }

  void completeWithJson(Object body) {
    if (_controller.isClosed) return;
    _ensureResponse();
    _controller
      ..add(utf8.encode(jsonEncode(body)))
      ..close();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return _response.future;
  }

  @override
  void close() {
    closeCalls++;
    _ensureResponse();
    if (!_controller.isClosed) {
      _controller.close();
    }
    super.close();
  }
}

class _ImmediateClient extends http.BaseClient {
  _ImmediateClient(this._body);

  final Object _body;
  int sendCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCalls++;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([
        utf8.encode(jsonEncode(_body)),
      ]),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

// ---------------------------------------------------------------------------
// Adversarial test clients. Each models one way the network can betray you.
// ---------------------------------------------------------------------------

/// Throws synchronously from send() — models DNS failure / connection refused.
class _ThrowingClient extends http.BaseClient {
  _ThrowingClient(this.error);
  final Object error;
  int closeCalls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw error;
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

/// Never completes send() — models a server that accepts the socket and then
/// goes silent. Used to prove the timeout fires instead of hanging forever.
class _HangingClient extends http.BaseClient {
  int closeCalls = 0;
  final _never = Completer<http.StreamedResponse>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _never.future;
  @override
  void close() {
    closeCalls++;
    super.close();
  }
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
  int sendCalls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCalls++;
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

void main() {
  group('DefaultHttpAdapter cancellation semantics', () {
    test('owned per-request client cancellation surfaces CancelError',
        () async {
      final client = _ProbeClient();
      final adapter = DefaultHttpAdapter(clientFactory: () => client);
      final token = CancelToken();

      final future = adapter.send(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/slow'),
          headers: const {'Accept': 'application/json'},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        ),
      );

      scheduleMicrotask(() => token.cancel('stop'));

      await expectLater(future, throwsA(isA<CancelError>()));
      expect(client.closeCalls, greaterThanOrEqualTo(1));
    });

    test('shared client mode does not close the injected client', () async {
      final client = _ProbeClient();
      final adapter = DefaultHttpAdapter(client: client);
      final token = CancelToken();
      addTearDown(client.close);

      final future = adapter.send(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/shared'),
          headers: const {'Accept': 'application/json'},
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        ),
      );

      scheduleMicrotask(() {
        token.cancel('stop');
        client.completeWithJson({'ok': true});
      });

      await expectLater(future, throwsA(isA<CancelError>()));
      expect(client.closeCalls, 0);
    });
  });

  group('DefaultHttpAdapter payload limits', () {
    test('request body over limit throws PayloadTooLargeError before send',
        () async {
      final client = _ImmediateClient(const {'ok': true});
      final adapter = DefaultHttpAdapter(client: client);

      final future = adapter.send(
        AdapterRequest(
          method: 'POST',
          url: Uri.parse('https://example.com/upload'),
          headers: const {'Content-Type': 'application/json'},
          body: utf8.encode('{"name":"abcdef"}'),
          timeout: const Duration(seconds: 5),
          maxRequestBodyBytes: 4,
        ),
      );

      await expectLater(future, throwsA(isA<PayloadTooLargeError>()));
      expect(client.sendCalls, 0);
    });

    test('response body over limit throws PayloadTooLargeError while streaming',
        () async {
      final client = _ImmediateClient(
        const {'message': 'this is too large'},
      );
      final adapter = DefaultHttpAdapter(client: client);

      final future = adapter.send(
        AdapterRequest(
          method: 'GET',
          url: Uri.parse('https://example.com/large'),
          headers: const {'Accept': 'application/json'},
          timeout: const Duration(seconds: 5),
          maxResponseBodyBytes: 4,
        ),
      );

      await expectLater(future, throwsA(isA<PayloadTooLargeError>()));
    });

    test('under-limit payload succeeds', () async {
      final client = _ImmediateClient(const {'ok': true});
      final adapter = DefaultHttpAdapter(client: client);

      final response = await adapter.send(
        AdapterRequest(
          method: 'POST',
          url: Uri.parse('https://example.com/ok'),
          headers: const {'Content-Type': 'application/json'},
          body: utf8.encode('{"ok":true}'),
          timeout: const Duration(seconds: 5),
          maxRequestBodyBytes: 1024,
          maxResponseBodyBytes: 1024,
        ),
      );

      expect(response.statusCode, 200);
      expect(client.sendCalls, 1);
    });
  });

  // =========================================================================
  // TRANSPORT FAILURES. Network down, reset, timeout: each must fail fast
  // with a typed error instead of hanging.
  // =========================================================================
  group('transport failures surface typed ApiException', () {
    test('connection refused / DNS failure -> NetworkError, client closed',
        () async {
      final c = _ThrowingClient(const _Sock('connection refused'));
      final api = _clientFor(c);
      final res = await api.get<dynamic>('down');
      expect(res.isFailure, true);
      expect(res.error, isA<NetworkError>());
      expect(c.closeCalls, 1, reason: 'owned client released on failure');
    });

    test('an ApiException thrown by transport is NOT re-wrapped', () async {
      // A SocketException-shaped failure that is already an ApiException must
      // pass through untouched (no NetworkError-around-NetworkError nesting).
      final c = _ThrowingClient(const NetworkError('already typed'));
      final api = _clientFor(c);
      final res = await api.get<dynamic>('down');
      expect(res.error, isA<NetworkError>());
      expect(res.error!.message, 'already typed');
    });

    test('silent server -> TimeoutError, no infinite hang', () async {
      final c = _HangingClient();
      final api = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: DefaultHttpAdapter(clientFactory: () => c),
      ));
      final res = await api.get<dynamic>(
        'slow',
        options: const RequestOptions(timeout: Duration(milliseconds: 50)),
      );
      expect(res.error, isA<TimeoutError>());
      expect(c.closeCalls, 1, reason: 'owned client closed on timeout');
    });

    test('connection reset mid-body -> NetworkError (buffered send)', () async {
      final c = _BodyErrorClient(
        200,
        [utf8.encode('{"par')],
        const _Sock('connection reset by peer'),
      );
      final api = _clientFor(c);
      final res = await api.get<dynamic>('reset');
      expect(res.isFailure, true);
      expect(res.error, isA<NetworkError>());
      expect(c.closeCalls, 1);
    });
  });

  // =========================================================================
  // SIZE GUARDS. Huge bodies must be rejected with PayloadTooLargeError
  // on BOTH directions, and never OOM the process by buffering unbounded.
  // =========================================================================
  group('payload size guards', () {
    test('oversized buffered RESPONSE -> PayloadTooLargeError(response)',
        () async {
      final c = _FixedClient(200, utf8.encode('x' * 100),
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c, maxResp: 10).get<dynamic>('big');
      expect(res.error, isA<PayloadTooLargeError>());
      final e = res.error as PayloadTooLargeError;
      expect(e.direction, 'response');
      expect(e.limitBytes, 10);
    });

    test('oversized REQUEST body -> PayloadTooLargeError(request), never sent',
        () async {
      final c = _FixedClient(200, utf8.encode('{}'),
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c, maxReq: 5).post<dynamic>(
          'big', {'payload': 'this is way more than five bytes'});
      expect(res.error, isA<PayloadTooLargeError>());
      expect((res.error as PayloadTooLargeError).direction, 'request');
      expect(c.sendCalls, 0, reason: 'rejected before reaching the transport');
      expect(c.closeCalls, 1, reason: 'client still released on request guard');
    });

    test('response exactly AT the limit is allowed (boundary, off-by-one)',
        () async {
      final c = _FixedClient(200, utf8.encode('1234567890'),
          headers: const {'content-type': 'application/json'});
      // body is "1234567890" (10 bytes) which is not valid JSON object but IS a
      // valid JSON number, so it decodes; the point is the size guard permits ==.
      final res = await _clientFor(c, maxResp: 10).get<dynamic>('edge');
      expect(res.isSuccess, true, reason: 'limit is a ceiling, not exclusive');
      expect(res.data, 1234567890);
    });
  });

  group('buffered send payload guard', () {
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
      expect(client.closeCalls, 1);
    });
  });

  group('DefaultHttpAdapter — body read deadline', () {
    test('a stalled response body surfaces TimeoutError instead of hanging',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        // ignore: close_sinks — the stall IS the scenario under test.
        final res = req.response;
        res.bufferOutput = false;
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.contentLength = 1024; // promise more bytes than we ever send
        res.add(utf8.encode('{"partial":'));
        await res.flush();
        // ...and stall forever: never write the rest, never close.
      });
      addTearDown(() => server.close(force: true));

      final adapter = DefaultHttpAdapter();
      await expectLater(
        adapter.send(AdapterRequest(
          method: 'GET',
          url: Uri.parse('http://127.0.0.1:${server.port}/stall'),
          headers: const {},
          timeout: const Duration(milliseconds: 400),
        )),
        throwsA(isA<TimeoutError>()),
      );
    });
  });
}
