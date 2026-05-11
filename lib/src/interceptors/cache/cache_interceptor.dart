import 'dart:typed_data';

import '../../core/query.dart';
import '../../http/http_adapter.dart';
import '../interceptor.dart';
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
  final CachePolicy? defaultPolicy;
  final Set<String> cacheMethods;

  static const _hitHeader = 'x-fac-cache-hit';
  static const _revalHeader = 'x-fac-cache-revalidate';

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
        if (entry != null) return ResolveResult(_toResponse(entry, true));
        return ResolveResult(
          AdapterResponse(
            statusCode: 504,
            headers: const {_hitHeader: 'miss'},
            bodyBytes: Uint8List(0),
            reasonPhrase: 'Gateway Timeout (cache-only miss)',
          ),
        );
      case CacheMode.cacheFirst:
        if (entry != null && entry.isFresh(policy.ttl)) {
          return ResolveResult(_toResponse(entry, true));
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
          req.headers[_revalHeader] = '1';
          if (entry.isFresh(policy.ttl)) {
            return ResolveResult(_toResponse(entry, true));
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
    final policy = _policyFor(req);
    if (policy == null) return ResolveResult(res);
    final key = _key(req);

    if (res.statusCode == 304) {
      final entry = await store.read(key);
      if (entry != null) return ResolveResult(_toResponse(entry, true));
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final etag = res.headers['etag'] ?? res.headers['ETag'];
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

  AdapterResponse _toResponse(CacheEntry e, bool hit) => AdapterResponse(
    statusCode: e.statusCode,
    headers: {...e.headers, _hitHeader: hit ? 'hit' : 'miss'},
    bodyBytes: e.bodyBytes,
  );

  String _key(InterceptedRequest req) {
    final url = buildUri(
      baseUrl: req.options.baseUrlOverride ?? '',
      endpoint: req.endpoint,
      queryParameters: req.options.queryParameters,
    ).toString();
    return '${req.method.toUpperCase()} $url';
  }
}
