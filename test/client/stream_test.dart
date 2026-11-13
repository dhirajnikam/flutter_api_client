import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiClient.stream', () {
    test('returns the body as a consumable stream (buffered fallback)',
        () async {
      final mock = MockAdapter();
      mock.on('GET', '/download', statusCode: 200, body: 'hello world');
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.example.com', adapter: mock),
      );

      final res = await client.stream('download');
      expect(res.isSuccess, true);
      expect(await res.data!.toText(), 'hello world');
    });
  });
}
