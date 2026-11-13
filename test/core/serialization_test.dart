import 'dart:convert';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A non-UTF-8 charset used to prove the charset hook is honoured.
class Latin1Charset implements Charset {
  const Latin1Charset();
  @override
  String decode(List<int> bytes) => latin1.decode(bytes);
  @override
  List<int> encode(String s) => latin1.encode(s);
}

/// A form-urlencoded body serializer used to prove serialization is pluggable.
class FormUrlEncodedSerializer implements RequestBodySerializer {
  const FormUrlEncodedSerializer();
  @override
  Object? encode(Object? data) {
    if (data == null) return null;
    if (data is Map) {
      return data.entries
          .map((e) =>
              '${Uri.encodeQueryComponent('${e.key}')}=${Uri.encodeQueryComponent('${e.value}')}')
          .join('&');
    }
    return data.toString();
  }
}

class _SpyJsonCodec implements ResponseJsonCodec {
  _SpyJsonCodec(this.onCall);
  final void Function() onCall;
  @override
  Object? decode(String source) {
    onCall();
    return jsonDecode(source);
  }
}

void main() {
  group('Pluggable serialization', () {
    test('default body serialization is byte-identical JSON', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );
      await client.post<dynamic>('x', {'a': 1, 'b': 'two'});
      expect(mock.received.single.body, utf8.encode('{"a":1,"b":"two"}'));
    });

    test('custom request body serializer is used', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          bodySerializer: const FormUrlEncodedSerializer(),
        ),
      );
      await client.post<dynamic>('x', {'a': 1, 'b': 'two'});
      expect(mock.received.single.body, 'a=1&b=two');
    });

    test('custom charset encodes string bodies', () async {
      final mock = MockAdapter()
        ..on('POST', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          charset: const Latin1Charset(),
          bodySerializer:
              const JsonRequestBodySerializer(charset: Latin1Charset()),
        ),
      );
      // 'é' is 0xE9 in latin1 (one byte) vs 0xC3 0xA9 in UTF-8 (two bytes).
      await client.post<dynamic>('x', 'é');
      expect(mock.received.single.body, [0xE9]);
    });

    test('custom response JSON codec is used', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'n': 1});
      var called = false;
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          responseJsonCodec: _SpyJsonCodec(() => called = true),
        ),
      );
      final res = await client.get<Map<String, dynamic>>('x');
      expect(res.isSuccess, true);
      expect(called, true);
    });
  });
}
