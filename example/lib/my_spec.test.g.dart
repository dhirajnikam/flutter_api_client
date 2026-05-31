// GENERATED CODE - DO NOT MODIFY BY HAND
// Run `dart run build_runner build` to regenerate.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_api_client_example/my_spec.dart';

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
