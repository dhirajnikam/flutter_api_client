// GENERATED CODE - DO NOT MODIFY BY HAND
// Run `dart run build_runner build` to regenerate.

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import './my_spec.dart';

void main() {
  test('spec loads without error', () {
    expect(mySpec, isNotNull);
    expect(mySpec.endpoints, isNotEmpty);
  });

  group('Endpoint registration', () {
    for (final ep in mySpec.endpoints) {
      test('${ep.method} ${ep.path} is registered', () {
        expect(ep.path, startsWith('/'));
        expect(ep.method, isNotEmpty);
      });
    }
  });
}
