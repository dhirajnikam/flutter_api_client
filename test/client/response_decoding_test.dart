import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

/// Latin-1 charset for exercising configurable response decoding.
class _Latin1Charset implements Charset {
  const _Latin1Charset();

  @override
  String decode(List<int> bytes) => latin1.decode(bytes);

  @override
  List<int> encode(String s) => latin1.encode(s);
}

void main() {
  // =========================================================================
  // HTTP STATUS MATRIX. 4xx/5xx/3xx must all become typed HttpError
  // carrying status + headers; success stays Success.
  // =========================================================================
  group('HTTP status code matrix', () {
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
  // DECODE EDGE CASES. Malformed/empty/huge JSON, wrong content-type,
  // HTML error pages. Decode must never crash; it yields a typed Failure or a
  // best-effort Success per the documented contract.
  // =========================================================================
  group('response decode edge cases', () {
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
      expect((res.error as HttpError).body, isNull);
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

    test('malformed UTF-8 in plainText mode -> ParseError, no crash', () async {
      final c = _FixedClient(200, [0xC3, 0x28, 0xA0, 0xA1],
          headers: const {'content-type': 'text/plain'});
      final res = await _clientFor(c).get<String>(
        't',
        options: const RequestOptions(responseType: ResponseType.plainText),
      );
      expect(res.isFailure, true,
          reason: 'invalid UTF-8 must degrade to a Failure, never crash');
      expect(res.error, isA<ParseError>());
    });
  });

  group('ResponseHandler HTML classification', () {
    const handler = ResponseHandler();

    test('lowercase doctype is classified as HTML', () {
      expect(
          handler.isHtmlOrTextResponse('<!doctype html><html></html>'), true);
    });

    test('uppercase HTML tag is classified as HTML', () {
      expect(handler.isHtmlOrTextResponse('<HTML><body>x</body></HTML>'), true);
    });

    test('doctype with attributes is classified as HTML', () {
      expect(
        handler.isHtmlOrTextResponse('<!DOCTYPE html PUBLIC "...">'),
        true,
      );
    });

    test('JSON object is not classified as HTML', () {
      expect(handler.isHtmlOrTextResponse('{"a":1}'), false);
    });
  });

  group('ResponseHandler — configured charset', () {
    test('error messages decode with the configured charset', () async {
      final mock = MockAdapter();
      mock.on(
        'POST',
        RegExp(r'/fermer$'),
        statusCode: 400,
        body: latin1.encode('{"message":"Café fermé"}'),
      );
      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        charset: const _Latin1Charset(),
      ));

      final result = await client.post<dynamic>('fermer', {'a': 1});

      expect(result.error, isA<HttpError>());
      expect(result.error!.message, 'Café fermé',
          reason: 'the Latin-1 body must decode with the configured charset, '
              'not hardcoded UTF-8');
    });
  });
}
