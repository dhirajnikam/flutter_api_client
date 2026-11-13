import 'dart:convert';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  // =========================================================================
  // FORM DATA / MULTIPART EDGE CASES.
  // =========================================================================
  group('FormData / multipart edge cases', () {
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

    test('non-string scalars are stringified', () {
      final fd = FormData.fromMap({'n': 42, 'b': true});
      expect(fd.fields, {'n': '42', 'b': 'true'});
    });
  });

  group('FormData.fromMap', () {
    test('collects MultipartFile into files list', () {
      final file = http.MultipartFile.fromString('upload', 'content');
      final fd = FormData.fromMap({'file': file});
      expect(fd.files, hasLength(1));
      expect(fd.files.first, same(file));
    });

    test('isEmpty and isNotEmpty reflect content', () {
      expect(FormData.fromMap({}).isEmpty, true);
      expect(FormData.fromMap({}).isNotEmpty, false);
      expect(FormData.fromMap({'k': 'v'}).isNotEmpty, true);
    });
  });
}
