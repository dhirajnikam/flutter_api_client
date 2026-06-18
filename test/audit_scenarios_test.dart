// FAILURE + EDGE-CASE SCENARIO MATRIX (work item w3, margaret-hamilton).
//
// "There was no second chance. We knew that. We took our work seriously, but
// we were also enjoying ourselves." The unhappy path is where missions are
// lost. This file enumerates the adverse scenarios the happy-path tests never
// reach and PROVES the transport + decode layers degrade gracefully: every
// failure surfaces as a typed `ApiException`/`Failure`, never an uncaught
// crash and never a silent hang.
//
// Scope (w3 fix zone): default_http_adapter, http_stream_response, http_adapter,
// mock_adapter, response/*, api_result, api_exception, response_type,
// cancel_token, query, form_data. The full decode wiring lives in
// api_client.dart (grace-hopper's); where a finding touches that file it is
// asserted at the public boundary here and reported to her via messages.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

void main() {
  // =========================================================================
  // GROUP 1 — TRANSPORT FAILURES. Network down, reset, timeout. The mission
  // must not hang; it must fail FAST with a typed error.
  // =========================================================================
  group('w3 · transport failures surface typed ApiException', () {
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
  // GROUP 2 — HTTP STATUS MATRIX. 4xx/5xx/3xx must all become typed HttpError
  // carrying status + headers; success stays Success.
  // =========================================================================
  group('w3 · HTTP status code matrix', () {
    Future<ApiResult<dynamic>> hit(int status, {String body = '{}'}) {
      final c = _FixedClient(status, utf8.encode(body),
          headers: const {'content-type': 'application/json'});
      return _clientFor(c).get<dynamic>('s');
    }

    for (final code in [400, 401, 403, 404, 409, 422, 429, 500, 502, 503]) {
      test('HTTP $code -> Failure(HttpError) carrying status', () async {
        final res = await hit(code, body: '{"message":"err $code"}');
        expect(res.isFailure, true);
        expect(res.error, isA<HttpError>());
        expect((res.error as HttpError).statusCode, code);
        expect(res.statusCode, code,
            reason: 'status surfaces on the Failure too');
      });
    }

    test('error response headers are preserved on Failure, not dropped',
        () async {
      final c = _FixedClient(503, utf8.encode('{"message":"down"}'), headers: {
        'content-type': 'application/json',
        'retry-after': '120',
      });
      final res = await _clientFor(c).get<dynamic>('s');
      expect(res.headers['retry-after'], '120');
      expect((res.error as HttpError).headers['retry-after'], '120');
    });

    test('2xx non-200 (201/204) treated as success', () async {
      final created = await hit(201, body: '{"id":1}');
      expect(created.isSuccess, true);
      expect(created.statusCode, 201);

      // 204 No Content with an empty body -> success with null data, no crash.
      final c = _FixedClient(204, const <int>[],
          headers: const {'content-type': 'application/json'});
      final noContent = await _clientFor(c).get<dynamic>('s');
      expect(noContent.isSuccess, true);
      expect(noContent.data, isNull);
    });

    test('3xx that reaches the client unfollowed is a non-2xx Failure',
        () async {
      // package:http follows redirects by default, but if a 3xx ever surfaces
      // to us (e.g. redirect: false upstream) it must be a typed HttpError, not
      // a misclassified success.
      final res = await hit(302, body: '');
      expect(res.isFailure, true);
      expect((res.error as HttpError).statusCode, 302);
    });
  });

  // =========================================================================
  // GROUP 3 — DECODE EDGE CASES. Malformed/empty/huge JSON, wrong content-type,
  // HTML error pages. Decode must never crash; it yields a typed Failure or a
  // best-effort Success per the documented contract.
  // =========================================================================
  group('w3 · response decode edge cases', () {
    test('malformed JSON on a 200 -> ParseError (not UnknownError)', () async {
      final c = _FixedClient(200, utf8.encode('{not json'),
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c).get<dynamic>('bad');
      expect(res.isFailure, true);
      expect(res.error, isA<ParseError>(),
          reason: 'corrupt success body is a parse failure, typed precisely');
    });

    test('HTML error page on a 200 -> ParseError classified as html', () async {
      final c = _FixedClient(
        200,
        utf8.encode(
            '<!DOCTYPE html><html><head></head><body>502</body></html>'),
        headers: const {'content-type': 'text/html'},
      );
      final res = await _clientFor(c).get<dynamic>('html');
      expect(res.error, isA<ParseError>());
      expect(res.error!.message, contains('text/html'));
    });

    test('empty 200 body -> Success with null data, no crash', () async {
      final c = _FixedClient(200, const <int>[],
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c).get<dynamic>('empty');
      expect(res.isSuccess, true);
      expect(res.data, isNull);
    });

    test('whitespace-only 200 body -> Success with null data', () async {
      final c = _FixedClient(200, utf8.encode('   \n  '),
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c).get<dynamic>('ws');
      expect(res.isSuccess, true);
      expect(res.data, isNull);
    });

    test('a supplied decoder that throws -> ParseError, not a leaked crash',
        () async {
      final c = _FixedClient(200, utf8.encode('{"a":1}'),
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c).get<int>(
        'd',
        decoder: (json) => throw StateError('boom in decoder'),
      );
      expect(res.error, isA<ParseError>());
    });

    test('wrong-shape JSON cast to wrong T -> ParseError, not TypeError crash',
        () async {
      // Body is a JSON object but caller asked for <String> with no decoder.
      final c = _FixedClient(200, utf8.encode('{"a":1}'),
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c).get<String>('cast');
      expect(res.isFailure, true);
      expect(res.error, isA<ParseError>(),
          reason: 'a bad cast is a contract/parse failure, surfaced typed');
    });

    test('malformed JSON on an error status decodes leniently to null body',
        () async {
      // On the ERROR path a corrupt body must not throw — the HttpError stands
      // on its own; the body is simply best-effort (null) and a message is
      // synthesised by the ResponseHandler.
      final c = _FixedClient(500, utf8.encode('<garbage not json'),
          headers: const {'content-type': 'application/json'});
      final res = await _clientFor(c).get<dynamic>('err');
      expect(res.isFailure, true);
      expect(res.error, isA<HttpError>());
      expect((res.error as HttpError).statusCode, 500);
    });

    test('plainText mode returns the raw string for any 2xx body', () async {
      final c = _FixedClient(200, utf8.encode('not-json-just-text'),
          headers: const {'content-type': 'text/plain'});
      final res = await _clientFor(c).get<String>(
        't',
        options: const RequestOptions(responseType: ResponseType.plainText),
      );
      expect(res.isSuccess, true);
      expect(res.data, 'not-json-just-text');
    });

    test('bytes mode returns raw Uint8List even for binary garbage', () async {
      final raw = Uint8List.fromList([0x00, 0xFF, 0xC3, 0x28, 0x7F]);
      final c = _FixedClient(200, raw,
          headers: const {'content-type': 'application/octet-stream'});
      final res = await _clientFor(c).get<Uint8List>(
        'b',
        options: const RequestOptions(responseType: ResponseType.bytes),
      );
      expect(res.isSuccess, true);
      expect(res.data, equals(raw),
          reason: 'bytes mode must not attempt UTF-8/JSON decode');
    });

    test(
        'MALFORMED UTF-8 in plainText mode is handled gracefully (no crash, '
        'returns a Failure)', () async {
      // Adverse: invalid UTF-8 byte sequence in a plainText 2xx response.
      // CONTRACT: must be a Failure (graceful), never an uncaught FormatException.
      // FINDING (reported to grace-hopper): the success plainText/stream path in
      // api_client decodes via utf8.decode() WITHOUT catching FormatException,
      // so it currently surfaces as UnknownError instead of ParseError. Either
      // way it is a graceful Failure; this test pins the graceful contract and
      // accepts the current typing until api_client tightens it.
      final c = _FixedClient(200, [0xC3, 0x28, 0xA0, 0xA1],
          headers: const {'content-type': 'text/plain'});
      final res = await _clientFor(c).get<String>(
        't',
        options: const RequestOptions(responseType: ResponseType.plainText),
      );
      expect(res.isFailure, true,
          reason: 'invalid UTF-8 must degrade to a Failure, never crash');
      expect(res.error, isA<ApiException>());
    });
  });

  // =========================================================================
  // GROUP 4 — SIZE GUARDS. Huge bodies must be rejected with PayloadTooLargeError
  // on BOTH directions, and never OOM the process by buffering unbounded.
  // =========================================================================
  group('w3 · payload size guards', () {
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

  // =========================================================================
  // GROUP 5 — STREAMING ADVERSITY. Backpressure, cancel, size-guard, and the
  // critical no-leak invariant: the owned client closes exactly once on EVERY
  // exit path.
  // =========================================================================
  group('w3 · streaming transport adversity', () {
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

  // =========================================================================
  // GROUP 6 — CANCELLATION (CancelToken). The token contract under stress:
  // idempotency, post-dispose safety, listener hygiene, mid-flight abort.
  // =========================================================================
  group('w3 · cancellation contract', () {
    test('cancel before send -> CancelError, request never hits the wire',
        () async {
      final c = _ManualBodyClient();
      final api = _clientFor(c);
      final token = CancelToken()..cancel('pre-empt');
      final res = await api.get<dynamic>('x',
          options: RequestOptions(cancelToken: token));
      expect(res.error, isA<CancelError>());
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

    test('CancelToken is idempotent and releases its listeners on cancel', () {
      final token = CancelToken();
      var fires = 0;
      token.addListener((_) => fires++);
      expect(token.listenerCount, 1);
      token.cancel();
      token.cancel('again'); // no-op
      expect(fires, 1, reason: 'listener fires exactly once');
      expect(token.listenerCount, 0, reason: 'listeners cleared after cancel');
      expect(token.isCancelled, true);
    });

    test('a disposed token can no longer be cancelled and fires nothing', () {
      final token = CancelToken();
      var fires = 0;
      token.dispose();
      token.addListener((_) => fires++); // never registered post-dispose
      token.cancel(); // no-op post-dispose
      expect(fires, 0);
      expect(token.isCancelled, false);
      expect(token.isDisposed, true);
    });

    test('a listener that throws does not abort cancellation of the others',
        () {
      final token = CancelToken();
      var second = false;
      token.addListener((_) => throw StateError('rude listener'));
      token.addListener((_) => second = true);
      token.cancel(); // must not propagate the StateError
      expect(second, true, reason: 'one bad listener cannot poison the rest');
    });
  });

  // =========================================================================
  // GROUP 7 — QUERY STRING + URI EDGE CASES. The places a naive builder emits a
  // malformed URL.
  // =========================================================================
  group('w3 · query + URI edge cases', () {
    test('null values are dropped, not encoded as "null"', () {
      expect(buildQueryString({'a': 1, 'b': null, 'c': 'x'}), 'a=1&c=x');
    });

    test('a map whose every value is null yields an empty query', () {
      expect(buildQueryString({'a': null, 'b': null}), '');
    });

    test('list values repeat the key', () {
      expect(
          buildQueryString({
            'id': [1, 2, 3]
          }),
          'id=1&id=2&id=3');
    });

    test('nested maps bracket the key', () {
      expect(
          buildQueryString({
            'filter': {'name': 'foo'}
          }),
          'filter%5Bname%5D=foo');
    });

    test('special characters in keys and values are percent-encoded', () {
      // Uri.encodeQueryComponent encodes a space as '+' (application/x-www-form-
      // urlencoded form-component semantics) and reserved chars (& =) as %xx.
      final q = buildQueryString({'a b': 'c&d=e', 'q': 'hello world'});
      expect(q, contains('a+b=c%26d%3De'));
      expect(q, contains('q=hello+world'));
    });

    test('buildUri normalises slashes and appends ? for a fresh query', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com/',
        endpoint: '/v1/items',
        queryParameters: {'page': 2},
      );
      expect(uri.toString(), 'https://api.example.com/v1/items?page=2');
    });

    test('buildUri uses & when the endpoint already carries a query', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items?sort=asc',
        queryParameters: {'page': 2},
      );
      expect(uri.toString(), 'https://api.example.com/items?sort=asc&page=2');
    });

    test('buildUri handles an endpoint ending in a bare ? (no double &)', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items?',
        queryParameters: {'page': 2},
      );
      expect(uri.toString(), 'https://api.example.com/items?page=2');
    });

    test('empty query parameters never append a stray ?', () {
      final uri = buildUri(
        baseUrl: 'https://api.example.com',
        endpoint: 'items',
        queryParameters: const {},
      );
      expect(uri.toString(), 'https://api.example.com/items');
    });

    test('a list value of nulls collapses to nothing', () {
      expect(
          buildQueryString({
            'id': [null, null]
          }),
          '');
    });
  });

  // =========================================================================
  // GROUP 8 — FORM DATA / MULTIPART EDGE CASES.
  // =========================================================================
  group('w3 · FormData / multipart edge cases', () {
    test('null map values are skipped', () {
      final fd = FormData.fromMap({'a': '1', 'b': null});
      expect(fd.fields, {'a': '1'});
      expect(fd.files, isEmpty);
    });

    test('list of scalars is indexed into bracketed field keys', () {
      final fd = FormData.fromMap({
        'tags': ['x', 'y']
      });
      expect(fd.fields, {'tags[0]': 'x', 'tags[1]': 'y'});
    });

    test('a single MultipartFile becomes a file part', () {
      final fd = FormData.fromMap({
        'doc': http.MultipartFile.fromBytes('doc', utf8.encode('hi'),
            filename: 'a.txt'),
      });
      expect(fd.files, hasLength(1));
      expect(fd.isNotEmpty, true);
    });

    test('a List<MultipartFile> becomes multiple file parts', () {
      final fd = FormData.fromMap({
        'docs': [
          http.MultipartFile.fromBytes('docs', utf8.encode('a')),
          http.MultipartFile.fromBytes('docs', utf8.encode('b')),
        ],
      });
      expect(fd.files, hasLength(2));
    });

    test('an entirely empty map is isEmpty', () {
      final fd = FormData.fromMap(const {});
      expect(fd.isEmpty, true);
      expect(fd.isNotEmpty, false);
    });

    test('non-string scalars are stringified', () {
      final fd = FormData.fromMap({'n': 42, 'b': true});
      expect(fd.fields, {'n': '42', 'b': 'true'});
    });
  });

  // =========================================================================
  // GROUP 9 — MOCK ADAPTER EDGE CASES (it backs nearly every test; its own
  // failure modes matter).
  // =========================================================================
  group('w3 · MockAdapter fallbacks', () {
    test('an unmatched route returns a typed 404, never throws', () async {
      final adapter = MockAdapter();
      final api = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: adapter));
      final res = await api.get<dynamic>('nowhere');
      expect(res.isFailure, true);
      expect((res.error as HttpError).statusCode, 404);
    });

    test('captures requests for assertion and matches by method + path',
        () async {
      final adapter = MockAdapter()
        ..on('GET', '/ping', statusCode: 200, body: {'ok': true});
      final api = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: adapter));
      final res = await api.get<dynamic>('ping');
      expect(res.isSuccess, true);
      expect(adapter.received, hasLength(1));
      expect(adapter.received.single.method, 'GET');
    });
  });

  // =========================================================================
  // GROUP 10 — ApiResult ALGEBRA. The sealed result must behave under map/when
  // on both branches, especially preserving header/status data across map.
  // =========================================================================
  group('w3 · ApiResult algebra invariants', () {
    test('map on Success transforms data and preserves status + headers', () {
      const r = Success<int>(2, statusCode: 200, headers: {'x': 'y'});
      final mapped = r.map((d) => d * 10);
      expect(mapped.data, 20);
      expect(mapped.statusCode, 200);
      expect(mapped.headers, {'x': 'y'});
    });

    test('map on Failure passes the error through unchanged and keeps headers',
        () {
      const r = Failure<int>(
        HttpError('boom', statusCode: 500, headers: {'retry-after': '5'}),
      );
      final mapped = r.map((d) => d.toString());
      expect(mapped.isFailure, true);
      expect(mapped.statusCode, 500);
      expect(mapped.headers, {'retry-after': '5'},
          reason: 'header data on a mapped Failure must not be silently lost');
    });

    test('when() is exhaustive over both branches', () {
      const ok = Success<int>(1, statusCode: 200);
      const fail = Failure<int>(NetworkError('x'));
      expect(ok.when(success: (_) => 'S', failure: (_) => 'F'), 'S');
      expect(fail.when(success: (_) => 'S', failure: (_) => 'F'), 'F');
    });

    test('transport Failure (no HttpError) has null status and empty headers',
        () {
      const r = Failure<int>(NetworkError('offline'));
      expect(r.statusCode, isNull);
      expect(r.headers, isEmpty);
      expect(r.errorMessage, 'offline');
    });
  });
}

/// Minimal exception standing in for a socket-level failure without importing
/// dart:io (which Flutter test discourages for pure-Dart adapter tests).
class _Sock implements Exception {
  const _Sock(this.message);
  final String message;
  @override
  String toString() => '_Sock: $message';
}
