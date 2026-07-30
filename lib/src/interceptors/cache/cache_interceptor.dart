import 'dart:typed_data';

import '../../core/api_exception.dart';
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
  /// Creates a cache interceptor backed by [store].
  CacheInterceptor({
    required this.store,
    this.defaultPolicy,
    this.cacheMethods = const {'GET'},
  });

  /// Backend that holds cached entries.
  final CacheStore store;

  /// Policy used when a request does not override it via
  /// [RequestOptions.cachePolicy]. `null` disables caching by default.
  final CachePolicy? defaultPolicy;

  /// HTTP methods eligible for caching (compared case-insensitively).
  final Set<String> cacheMethods;

  static const _hitHeader = cacheHitHeader;

  CachePolicy? _policyFor(InterceptedRequest req) {
    final override = req.options.cachePolicy;
    if (override is CachePolicy) return override;
    return defaultPolicy;
  }

  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    if (!cacheMethods.contains(req.method.toUpperCase())) {
      return ProceedResult(req);
    }
    final policy = _policyFor(req);
    if (policy == null) return ProceedResult(req);

    final key = _key(req);
    final entry = await store.read(key);

    switch (policy.mode) {
      case CacheMode.cacheOnly:
        if (entry != null) return ResolveResult(_toResponse(entry));
        return ResolveResult(
          AdapterResponse(
            statusCode: 504,
            headers: const {_hitHeader: cacheMissValue},
            bodyBytes: Uint8List(0),
            reasonPhrase: 'Gateway Timeout (cache-only miss)',
          ),
        );
      case CacheMode.cacheFirst:
        if (entry != null && entry.isFresh(policy.ttl)) {
          return ResolveResult(_toResponse(entry));
        }
        if (entry?.etag != null && policy.useEtag) {
          req.headers['If-None-Match'] = entry!.etag!;
        }
        return ProceedResult(req);
      case CacheMode.networkFirst:
        if (entry?.etag != null && policy.useEtag) {
          req.headers['If-None-Match'] = entry!.etag!;
        }
        return ProceedResult(req);
      case CacheMode.staleWhileRevalidate:
        if (entry != null) {
          if (entry.isFresh(policy.ttl)) {
            return ResolveResult(_toResponse(entry));
          }
          if (entry.etag != null && policy.useEtag) {
            req.headers['If-None-Match'] = entry.etag!;
          }
        }
        return ProceedResult(req);
    }
  }

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    if (!cacheMethods.contains(req.method.toUpperCase())) {
      return ResolveResult(res);
    }
    // A streaming body is not buffered, so there is nothing to cache.
    if (res.bodyStream != null) return ResolveResult(res);
    // A response we served ourselves (cache hit, stale-on-error fallback, or
    // the synthetic cacheOnly-miss 504) carries the marker header. Re-writing
    // it would refresh savedAt on every hit, sliding the TTL so a steadily
    // re-read entry never expires; freshness must be measured from when the
    // body was actually fetched from the origin, so skip the store entirely.
    if (res.headers[_hitHeader] != null) return ResolveResult(res);
    final policy = _policyFor(req);
    if (policy == null) return ResolveResult(res);

    if (res.statusCode == 304) {
      final key = _key(req);
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
      final key = _key(req);
      final etag = headerValue(res.headers, 'etag');
      await store.write(
        CacheEntry(
          key: key,
          statusCode: res.statusCode,
          headers: res.headers,
          bodyBytes: res.bodyBytes,
          savedAt: DateTime.now(),
          etag: etag,
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
    if (!cacheMethods.contains(req.method.toUpperCase())) {
      return RejectResult(error);
    }
    final policy = _policyFor(req);
    if (policy == null) return RejectResult(error);
    // Any read-through mode that keeps a copy should be able to serve it when
    // the network is unreachable. cacheOnly never reaches the network (so it
    // never lands here); the other three should all degrade gracefully to the
    // last-known-good body on a transient failure rather than surfacing an
    // error the cache could have answered.
    switch (policy.mode) {
      case CacheMode.cacheOnly:
        return RejectResult(error);
      case CacheMode.networkFirst:
      case CacheMode.cacheFirst:
      case CacheMode.staleWhileRevalidate:
        break;
    }
    if (error is! NetworkError && error is! TimeoutError) {
      return RejectResult(error);
    }

    final entry = await store.read(_key(req));
    if (entry != null) {
      return ResolveResult(_toResponse(entry));
    }
    return RejectResult(error);
  }

  /// Builds a response served from a [CacheEntry], tagged with the cache-hit
  /// marker header so downstream code can tell it came from the cache.
  AdapterResponse _toResponse(CacheEntry e) => AdapterResponse(
        statusCode: e.statusCode,
        headers: {...e.headers, _hitHeader: cacheHitValue},
        bodyBytes: e.bodyBytes,
      );

  String _key(InterceptedRequest req) => requestIdentityKey(req);
}
