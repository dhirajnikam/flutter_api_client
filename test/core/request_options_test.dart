import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RequestOptions', () {
    test('copyWith', () {
      const o = RequestOptions();
      final n = o.copyWith(
        includeToken: false,
        maxRequestBodyBytes: 10,
        maxResponseBodyBytes: 20,
      );
      expect(n.includeToken, false);
      expect(n.maxRequestBodyBytes, 10);
      expect(n.maxResponseBodyBytes, 20);
    });
  });
}
