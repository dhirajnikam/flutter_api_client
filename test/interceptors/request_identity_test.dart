import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  // ===========================================================================
  // Request identity and reserved headers.
  //   Reserved `x-fac-*` request headers and `If-None-Match` are not part of a
  //   request's identity (a conditional revalidation must key to the entry it
  //   revalidates), meaningful headers are, and no `x-fac-*` header is ever
  //   sent to the origin.
  // ===========================================================================
  group('request identity and reserved headers', () {
    ({ApiClient client, MockAdapter mock}) cached() {
      final mock = MockAdapter();
      mock.onRequest(
        'GET',
        RegExp(r'/r$'),
        (_) async => AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: _b('"v"'),
        ),
      );
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          CacheInterceptor(
            store: MemoryCacheStore(),
            defaultPolicy: CachePolicy.cacheFirst(),
          ),
        ],
      ));
      return (client: client, mock: mock);
    }

    test('reserved and revalidation headers do not change request identity',
        () async {
      final (:client, :mock) = cached();
      await client.get<dynamic>('r');
      final second = await client.get<dynamic>(
        'r',
        options: const RequestOptions(headers: {
          'x-fac-offline-replay': '1',
          'X-Fac-Anything': 'whatever',
          'if-none-match': 'W/"v1"',
        }),
      );
      expect(second.data, 'v');
      expect(mock.received, hasLength(1),
          reason: 'same identity => served from the first request\'s entry');
    });

    test('a meaningful header (Accept) DOES change request identity', () async {
      final (:client, :mock) = cached();
      await client.get<dynamic>('r',
          options: const RequestOptions(headers: {'Accept': 'a'}));
      await client.get<dynamic>('r',
          options: const RequestOptions(headers: {'Accept': 'b'}));
      expect(mock.received, hasLength(2),
          reason: 'different Accept => different cache entry');
    });

    test('reserved x-fac-* request headers never reach the adapter', () async {
      final mock = MockAdapter();
      mock.on('GET', RegExp(r'/r$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(ApiClientConfig.test(
          baseUrl: 'https://api.example.com', adapter: mock));
      await client.get<dynamic>(
        'r',
        options: const RequestOptions(headers: {
          'Authorization': 'Bearer x',
          'x-fac-retry-attempt': '2',
          'X-Fac-Dedup-Key': 'k',
          'Accept': 'application/json',
        }),
      );
      final sent = mock.received.single.headers;
      expect(sent.keys.where((k) => k.toLowerCase().startsWith('x-fac-')),
          isEmpty);
      expect(sent['Authorization'], 'Bearer x',
          reason: 'Authorization is NOT internal — it goes on the wire');
      expect(sent['Accept'], 'application/json');
    });
  });
}
