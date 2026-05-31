import 'dart:async';
import 'dart:convert';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('DefaultHttpAdapter cancellation semantics', () {
    test('owned per-request client cancellation surfaces CancelError', () async {
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
      expect(client.closeCalls, 1);
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
}

class _ProbeClient extends http.BaseClient {
  final _controller = StreamController<List<int>>();
  int closeCalls = 0;

  void completeWithJson(Object body) {
    if (_controller.isClosed) return;
    _controller
      ..add(utf8.encode(jsonEncode(body)))
      ..close();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      _controller.stream,
      200,
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  void close() {
    closeCalls++;
    if (!_controller.isClosed) {
      _controller.close();
    }
    super.close();
  }
}
