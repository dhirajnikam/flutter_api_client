import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cursor page in the style of most REST feeds.
class _Page {
  _Page(this.items, this.nextCursor);
  final List<int> items;
  final String? nextCursor;
}

void main() {
  group('Paginator — cursor pagination', () {
    Paginator<int, _Page> cursorPaginator({int pages = 3, int? maxPages}) {
      final data = {
        for (var p = 0; p < pages; p++)
          p == 0 ? null : 'c$p': _Page(
            [p * 10, p * 10 + 1],
            p < pages - 1 ? 'c${p + 1}' : null,
          ),
      };
      return Paginator<int, _Page>(
        fetchPage: (prev) async {
          final page = data[prev?.nextCursor]!;
          return Success(page, statusCode: 200);
        },
        itemsOf: (page) => page.items,
        hasMore: (page) => page.nextCursor != null,
        maxPages: maxPages,
      );
    }

    test('pages() walks the cursor chain in order', () async {
      final pages = await cursorPaginator().pages().toList();
      expect(pages, hasLength(3));
      expect(pages.map((p) => p.items.first), [0, 10, 20]);
    });

    test('items() flattens pages in order', () async {
      final items = await cursorPaginator().items().toList();
      expect(items, [0, 1, 10, 11, 20, 21]);
    });

    test('all() collects every item into one Success', () async {
      final result = await cursorPaginator().all();
      expect(result.isSuccess, true);
      expect(result.data, [0, 1, 10, 11, 20, 21]);
      expect(result.statusCode, 200);
    });

    test('maxPages caps the walk', () async {
      final result = await cursorPaginator(maxPages: 2).all();
      expect(result.data, [0, 1, 10, 11]);
    });

    test('maxItems truncates and stops fetching early', () async {
      var fetches = 0;
      final paginator = Paginator<int, _Page>(
        fetchPage: (prev) async {
          fetches++;
          return Success(
            _Page([fetches * 10, fetches * 10 + 1], 'c$fetches'),
            statusCode: 200,
          );
        },
        itemsOf: (page) => page.items,
        hasMore: (page) => true,
      );

      final result = await paginator.all(maxItems: 3);
      expect(result.data, [10, 11, 20]);
      expect(fetches, 2, reason: 'third page never requested');
    });

    test('each call starts a fresh walk', () async {
      final paginator = cursorPaginator();
      expect((await paginator.all()).data, hasLength(6));
      expect((await paginator.all()).data, hasLength(6));
    });
  });

  group('Paginator — failure semantics', () {
    Paginator<int, _Page> failingOnSecond() {
      var fetches = 0;
      return Paginator<int, _Page>(
        fetchPage: (prev) async {
          fetches++;
          if (fetches == 2) {
            return const Failure(NetworkError('offline'));
          }
          return Success(_Page([1, 2], 'next'), statusCode: 200);
        },
        itemsOf: (page) => page.items,
        hasMore: (page) => page.nextCursor != null,
      );
    }

    test('pages() surfaces the ApiException as a stream error', () async {
      final seen = <_Page>[];
      Object? caught;
      try {
        await for (final page in failingOnSecond().pages()) {
          seen.add(page);
        }
      } catch (e) {
        caught = e;
      }
      expect(seen, hasLength(1), reason: 'first page was already delivered');
      expect(caught, isA<NetworkError>());
    });

    test('all() returns the Failure verbatim, discarding partial items',
        () async {
      final result = await failingOnSecond().all();
      expect(result.isFailure, true);
      expect(result.error, isA<NetworkError>());
      expect(result.data, isNull);
    });
  });

  group('Paginator — default hasMore (stop on empty page)', () {
    test('walks until a page yields no items', () async {
      final pages = [
        [1, 2],
        [3],
        <int>[],
      ];
      var fetches = 0;
      final paginator = Paginator<int, List<int>>(
        fetchPage: (prev) async => Success(pages[fetches++], statusCode: 200),
        itemsOf: (page) => page,
      );

      final result = await paginator.all();
      expect(result.data, [1, 2, 3]);
      expect(fetches, 3, reason: 'the empty page is the stop signal');
    });

    test('pages() does not emit the trailing empty page', () async {
      final pages = [
        [1],
        <int>[],
      ];
      var fetches = 0;
      final paginator = Paginator<int, List<int>>(
        fetchPage: (prev) async => Success(pages[fetches++], statusCode: 200),
        itemsOf: (page) => page,
      );

      final emitted = await paginator.pages().toList();
      expect(emitted, hasLength(1));
    });
  });

  group('Paginator — end to end with ApiClient', () {
    test('page-number pagination against a mock API', () async {
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/users$'), (req) async {
        final page = int.parse(req.url.queryParameters['page']!);
        final body = switch (page) {
          1 => '[{"id":1},{"id":2}]',
          2 => '[{"id":3}]',
          _ => '[]',
        };
        return AdapterResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBytes: Uint8List.fromList(body.codeUnits),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
            baseUrl: 'https://api.example.com', adapter: mock),
      );

      var page = 0;
      final paginator = Paginator<int, List<dynamic>>(
        fetchPage: (_) => client.get<List<dynamic>>(
          'users',
          options: RequestOptions(queryParameters: {'page': '${++page}'}),
        ),
        itemsOf: (users) =>
            [for (final u in users) (u as Map<String, dynamic>)['id'] as int],
        hasMore: (users) => users.length == 2,
      );

      final result = await paginator.all();
      expect(result.isSuccess, true);
      expect(result.data, [1, 2, 3]);
      expect(mock.received, hasLength(2));
    });
  });
}
