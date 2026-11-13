import 'dart:async';
import 'dart:convert';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Feeds the body manually via a controller. Lets a test stall mid-stream.
class _ManualBodyClient extends http.BaseClient {
  _ManualBodyClient();
  final int status = 200;
  // ignore: close_sinks
  final body = StreamController<List<int>>();
  int closeCalls = 0;
  int sendCalls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCalls++;
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

void main() {
  // =========================================================================
  // CANCELLATION through the client: pre-send and mid-flight abort.
  // =========================================================================
  group('cancellation contract', () {
    test('cancel before send -> CancelError, request never hits the wire',
        () async {
      final c = _ManualBodyClient();
      final api = _clientFor(c);
      final token = CancelToken()..cancel('pre-empt');
      final res = await api.get<dynamic>('x',
          options: RequestOptions(cancelToken: token));
      expect(res.error, isA<CancelError>());
      expect(c.sendCalls, 0, reason: 'a pre-cancelled request is never sent');
    });

    test('cancel mid buffered-body -> CancelError, client closed', () async {
      final c = _ManualBodyClient();
      final api = _clientFor(c);
      final token = CancelToken();
      final fut =
          api.get<dynamic>('x', options: RequestOptions(cancelToken: token));
      c.body.add(utf8.encode('partial'));
      await Future<void>.delayed(Duration.zero);
      token.cancel('user abort');
      final res = await fut;
      expect(res.error, isA<CancelError>());
      expect(c.closeCalls, 1);
    });
  });
}
