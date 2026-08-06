import 'api_exception.dart';
import 'api_result.dart';

/// Walks a paginated endpoint page by page, exposing the pages (or the items
/// inside them) as streams, or collecting everything with [all].
///
/// The paginator is deliberately shape-agnostic: you supply [fetchPage]
/// (which sees the previous page, so it can read a cursor, a next-URL, or
/// keep its own page counter), [itemsOf] to pull the items out of a page,
/// and [hasMore] to say when to stop. It works with any `ApiClient` call —
/// or anything else that returns an [ApiResult].
///
/// Cursor-based feed:
/// ```dart
/// final paginator = Paginator<Post, Feed>(
///   fetchPage: (prev) => client.get(
///     'feed',
///     options: RequestOptions(queryParameters: {
///       if (prev != null) 'cursor': prev.nextCursor,
///     }),
///     decoder: Feed.fromJson,
///   ),
///   itemsOf: (page) => page.posts,
///   hasMore: (page) => page.nextCursor != null,
/// );
///
/// await for (final post in paginator.items()) { ... }
/// ```
///
/// Page-number API:
/// ```dart
/// var page = 0;
/// final paginator = Paginator<User, List<User>>(
///   fetchPage: (_) => client.get(
///     'users',
///     options: RequestOptions(queryParameters: {'page': ++page, 'size': 50}),
///     decoder: (j) => [for (final u in j as List) User.fromJson(u)],
///   ),
///   itemsOf: (users) => users,
///   hasMore: (users) => users.length == 50,
/// );
/// final all = await paginator.all();
/// ```
///
/// Each call to [pages], [items], or [all] starts a fresh walk from the first
/// page; the paginator object holds no iteration state itself.
class Paginator<TItem, TPage> {
  /// Creates a paginator. See the field docs for each parameter's meaning.
  Paginator({
    required this.fetchPage,
    required this.itemsOf,
    bool Function(TPage page)? hasMore,
    this.maxPages,
  })  : hasMore = hasMore ?? ((page) => true),
        _defaultHasMore = hasMore == null,
        assert(maxPages == null || maxPages > 0, 'maxPages must be positive');

  /// Fetches the next page. Receives the previously fetched page (null for
  /// the first request) so it can carry a cursor or next-link forward.
  final Future<ApiResult<TPage>> Function(TPage? previousPage) fetchPage;

  /// Extracts the items from a page.
  final List<TItem> Function(TPage page) itemsOf;

  /// Whether another page should be fetched after [page]. When omitted, the
  /// walk continues until a page yields no items (which costs one trailing
  /// empty-page request — supply [hasMore] to stop precisely).
  final bool Function(TPage page) hasMore;

  /// True when the caller relied on the default "stop on an empty page" rule.
  final bool _defaultHasMore;

  /// Hard cap on pages fetched per walk, as a runaway guard against an API
  /// whose cursor never ends. `null` means unbounded.
  final int? maxPages;

  /// Fetched pages, in order. A failed fetch surfaces its [ApiException] as a
  /// stream error and ends the stream; pages already emitted stay delivered.
  Stream<TPage> pages() async* {
    TPage? previous;
    var fetched = 0;
    while (maxPages == null || fetched < maxPages!) {
      final result = await fetchPage(previous);
      switch (result) {
        case Success<TPage>(:final data):
          fetched++;
          if (_defaultHasMore && itemsOf(data).isEmpty) return;
          yield data;
          if (!hasMore(data)) return;
          previous = data;
        case Failure<TPage>(:final error):
          throw error;
      }
    }
  }

  /// Items from every page, in order. Failure semantics match [pages].
  Stream<TItem> items() async* {
    await for (final page in pages()) {
      for (final item in itemsOf(page)) {
        yield item;
      }
    }
  }

  /// Fetches pages until exhausted (or [maxItems]/[maxPages] is hit) and
  /// returns all items as one list.
  ///
  /// Failure short-circuits: a failed page fetch returns that [Failure]
  /// verbatim and items from earlier pages are discarded — partial data is
  /// never silently presented as the full set. The returned [Success] carries
  /// the status code and headers of the LAST page fetched.
  Future<ApiResult<List<TItem>>> all({int? maxItems}) async {
    assert(maxItems == null || maxItems > 0, 'maxItems must be positive');
    final collected = <TItem>[];
    TPage? previous;
    var fetched = 0;
    int? lastStatusCode;
    var lastHeaders = const <String, String>{};
    while (maxPages == null || fetched < maxPages!) {
      final result = await fetchPage(previous);
      switch (result) {
        case Success<TPage>(:final data, :final statusCode, :final headers):
          fetched++;
          lastStatusCode = statusCode;
          lastHeaders = headers;
          collected.addAll(itemsOf(data));
          if (maxItems != null && collected.length >= maxItems) {
            return Success<List<TItem>>(
              collected.sublist(0, maxItems),
              statusCode: statusCode,
              headers: headers,
            );
          }
          if (!hasMore(data) || (_defaultHasMore && itemsOf(data).isEmpty)) {
            return Success<List<TItem>>(
              collected,
              statusCode: statusCode,
              headers: headers,
            );
          }
          previous = data;
        case Failure<TPage>(:final error, :final statusCode):
          return Failure<List<TItem>>(error, statusCode: statusCode);
      }
    }
    // Reachable only when maxPages stopped the walk, so at least one page was
    // fetched and lastStatusCode is set.
    return Success<List<TItem>>(
      collected,
      statusCode: lastStatusCode!,
      headers: lastHeaders,
    );
  }
}
