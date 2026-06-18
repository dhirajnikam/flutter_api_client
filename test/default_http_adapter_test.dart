import 'dart:async';
import 'dart:convert';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

      test(
          'response body over limit throws PayloadTooLargeError while streaming',
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
  });
}

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
