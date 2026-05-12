import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('@ApiSpecEntry annotation', () {
    test('can be instantiated as const', () {
      const entry = ApiSpecEntry();
      expect(entry, isNotNull);
    });

    test('two const instances are identical (const canonicalization)', () {
      const a = ApiSpecEntry();
      const b = ApiSpecEntry();
      expect(identical(a, b), true);
    });
  });
}
