import 'dart:typed_data';

import '../../core/api_exception.dart';
import '../../core/error_classification.dart';
import '../../core/headers.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
import '../internal_headers.dart';
import '../request_identity.dart';
import 'cache_policy.dart';
import 'cache_store.dart';

/// Caches GET responses according to a [CachePolicy].
///
/// Supports `networkFirst`, `cacheFirst`, `staleWhileRevalidate` and
/// `cacheOnly` strategies, plus ETag / If-None-Match revalidation.
class CacheInterceptor extends Interceptor {
  CacheInterceptor({
    required this.store,
    this.defaultPolicy,
    this.cacheMethods = const {'GET'},
  });

  final CacheStore store;

  /// Policy used when a request does not override it via
  /// [RequestOptions.cachePolicy]. `null` disables caching by default.
  final CachePolicy? defaultPolicy;

  /// HTTP methods eligible for caching (compared case-insensitively).
  final Set<String> cacheMethods;

  /// The policy caching [req] under, or `null` when it is not cached at all.
  CachePolicy? _policyFor(InterceptedRequest req) {
    if (!cacheMethods.contains(req.method.toUpperCase())) return null;
    final override = req.options.cachePolicy;
    return override is CachePolicy ? override : defaultPolicy;
  }

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    final policy = _policyFor(req);
    if (policy == null) return ProceedResult(req);

    final entry = await store.read(requestIdentityKey(req));

    switch (policy.mode) {
      case CacheMode.cacheOnly:
        if (entry != null) return ResolveResult(_toResponse(entry));
        return ResolveResult(
          AdapterResponse(
            statusCode: 504,
            headers: const {cacheHitHeader: cacheMissValue},
            bodyBytes: Uint8List(0),
            reasonPhrase: 'Gateway Timeout (cache-only miss)',
          ),
        );
      case CacheMode.cacheFirst:
      case CacheMode.staleWhileRevalidate:
        if (entry != null && entry.isFresh(policy.ttl)) {
          return ResolveResult(_toResponse(entry));
        }
      case CacheMode.networkFirst:
        break;
    }
    final etag = entry?.etag;
    if (etag != null && policy.useEtag) req.headers['If-None-Match'] = etag;
    return ProceedResult(req);
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    final policy = _policyFor(req);
    if (policy == null) return ResolveResult(res);
    // A streaming body is not buffered, so there is nothing to cache.
    if (res.bodyStream != null) return ResolveResult(res);
    // Re-writing a response we served ourselves would refresh savedAt on every
    // hit, sliding the TTL so a steadily re-read entry never expires;
    // freshness must be measured from when the body was actually fetched from
    // the origin.
    if (isCacheFabricated(res)) return ResolveResult(res);

    final key = requestIdentityKey(req);
    if (res.statusCode == 304) {
      final entry = await store.read(key);
      if (entry == null) {
        // The entry was evicted while the conditional request was in flight:
        // a bare 304 has no body to serve. Drop the stale validator and re-run
        // the chain for a full response (bounded by the chain's retryDepth).
        await store.delete(key);
        final retry = req.copy();
        retry.headers.removeWhere((k, _) => k.toLowerCase() == 'if-none-match');
        return ProceedResult(retry);
      }
      // A 304 means the origin confirmed the cached body is still current,
      // so restart its freshness window. Without refreshing savedAt the
      // entry stays "stale" forever and every future request revalidates,
      // defeating the TTL. Carry forward an updated ETag if the 304 sent one.
      final refreshed = CacheEntry(
        key: entry.key,
        statusCode: entry.statusCode,
        headers: entry.headers,
        bodyBytes: entry.bodyBytes,
        savedAt: DateTime.now(),
        etag: headerValue(res.headers, 'etag') ?? entry.etag,
      );
      await store.write(refreshed);
      return ResolveResult(_toResponse(refreshed));
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      await store.write(
        CacheEntry(
          key: key,
          statusCode: res.statusCode,
          headers: res.headers,
          bodyBytes: res.bodyBytes,
          savedAt: DateTime.now(),
          etag: headerValue(res.headers, 'etag'),
        ),
      );
    }
    return ResolveResult(res);
  }

  @override
  Future<InterceptorResult> onError(
    InterceptedRequest req,
    ApiException error,
  ) async {
    final policy = _policyFor(req);
    // Every read-through mode degrades to the last-known-good body when the
    // network is unreachable. cacheOnly never reaches the network.
    if (policy == null ||
        policy.mode == CacheMode.cacheOnly ||
        !error.isTransient) {
      return RejectResult(error);
    }
    final entry = await store.read(requestIdentityKey(req));
    if (entry != null) return ResolveResult(_toResponse(entry));
    return RejectResult(error);
  }

  AdapterResponse _toResponse(CacheEntry e) => AdapterResponse(
        statusCode: e.statusCode,
        headers: {...e.headers, cacheHitHeader: cacheHitValue},
        bodyBytes: e.bodyBytes,
      );

  /// Drops every cached entry whose identity key satisfies [test].
  ///
  /// Cache keys are `requestIdentityKey` values — `METHOD url` followed by the
  /// sorted request headers (the credential as a digest) — so they cannot
  /// practically be reconstructed by hand and a plain `delete(key)` is unusable
  /// from application code. Match on the key text instead:
  ///
  /// ```dart
  /// // After a write that changes what /todos returns.
  /// await cache.evictWhere((key) => key.contains('/todos'));
  /// ```
  ///
  /// Returns the number of entries removed. Stores that do not implement
  /// [EnumerableCacheStore] cannot be enumerated, so they remove nothing and
  /// return `0`.
  Future<int> evictWhere(bool Function(String key) test) async {
    final s = store;
    if (s is! EnumerableCacheStore) return 0;
    // Materialise first: deleting while iterating the store's own view is not
    // safe for every backend.
    final matched = (await s.keys()).where(test).toList();
    for (final key in matched) {
      await store.delete(key);
    }
    return matched.length;
  }

  /// Drops every cached entry whose URL contains [endpoint].
  ///
  /// The common case behind [evictWhere]: invalidate one list endpoint after a
  /// write without clearing the whole store. Matching is a substring test over
  /// the key's `METHOD url` prefix, so it catches the endpoint regardless of
  /// base URL, query string, or which credentials cached it.
  ///
  /// Returns the number of entries removed.
  Future<int> evictEndpoint(String endpoint) =>
      // ponytail: substring match, not URL parsing. Upgrade to a parsed-path
      // comparison if an endpoint name ever collides with a query value.
      evictWhere((key) {
        // Only the first line is `METHOD url`; the rest are headers, whose
        // values must not be able to trigger an eviction.
        final newline = key.indexOf('\n');
        final firstLine = newline == -1 ? key : key.substring(0, newline);
        return firstLine.contains(endpoint);
      });
}
