import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the 1.1.0 audit fixes. Each guards a specific bug that
/// previously shipped broken output or silently passed bad input.
void main() {
  group('TestGenerator — special-character escaping', () {
    test('escapes quotes, dollar signs and backslashes in body examples', () {
      final spec = ApiSpec(
        title: 'T',
        version: '1',
        baseUrl: 'https://api.example.com',
      )..group('Items', (g) {
          g.endpoint(
            'POST /items',
            request: const RequestExample(body: {
              'name': "O'Brien",
              'note': r'pa$word',
              'path': r'C:\tmp',
            }),
            responses: [ResponseExample.created({'id': 1})],
          );
        });

      final src = TestGenerator(spec).generate();

      // Escaped forms present; the raw (compile-breaking) forms absent.
      expect(src, contains(r"O\'Brien"));
      expect(src, contains(r'pa\$word'));
      expect(src, contains(r'C:\\tmp'));
      expect(src.contains("'O'Brien'"), isFalse);
    });
  });

  group('TestGenerator — unsupported HTTP methods', () {
    test('skips HEAD endpoints instead of emitting client.head()', () {
      final spec = ApiSpec(
        title: 'T',
        version: '1',
        baseUrl: 'https://api.example.com',
      )..group('Ping', (g) {
          g.endpoint('HEAD /ping', responses: [ResponseExample.ok({})]);
        });

      final src = TestGenerator(spec).generate();

      expect(src.contains('client.head'), isFalse);
      expect(src, contains('skipped'));
    });
  });

  group('Schema.validate — unknown type', () {
    test('an unknown schema type fails validation instead of passing', () {
      final errors = const Schema(type: 'bogus').validate('anything');
      expect(errors, isNotEmpty);
      expect(errors.first, contains('unknown schema type'));
    });
  });

  group('InMemoryOfflineQueueStore.drain — ordering', () {
    test('returns requests oldest createdAt first regardless of enqueue order',
        () async {
      final store = InMemoryOfflineQueueStore();
      final older = QueuedRequest(
        id: 'a',
        method: 'POST',
        endpoint: '/a',
        headers: const {},
        createdAt: DateTime.utc(2020),
      );
      final newer = QueuedRequest(
        id: 'b',
        method: 'POST',
        endpoint: '/b',
        headers: const {},
        createdAt: DateTime.utc(2021),
      );

      // Enqueue out of createdAt order.
      await store.enqueue(newer);
      await store.enqueue(older);

      final drained = await store.drain();
      expect(drained.map((r) => r.id).toList(), ['a', 'b']);
    });
  });
}
