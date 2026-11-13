import '../core/headers.dart';
import '../http/http_adapter.dart';
import 'interceptor.dart';

/// Every header starting with this prefix is reserved for coordination inside
/// the client. Such request headers are never sent to the origin, persisted,
/// or counted as part of a request's identity.
const String internalHeaderPrefix = 'x-fac-';

/// Whether [name] is a reserved internal header. Matched case-insensitively.
bool isInternalHeader(String name) =>
    name.toLowerCase().startsWith(internalHeaderPrefix);

/// Returns a copy of [headers] with every internal header removed.
Map<String, String> stripInternalHeaders(Map<String, String> headers) => {
      for (final entry in headers.entries)
        if (!isInternalHeader(entry.key)) entry.key: entry.value,
    };

/// Response header the cache interceptor uses to mark responses it fabricated
/// itself: `hit` for a body served from the store, `miss` for the synthetic
/// 504 a `cacheOnly` miss resolves with.
const String cacheHitHeader = 'x-fac-cache-hit';

const String cacheHitValue = 'hit';

const String cacheMissValue = 'miss';

/// Whether the cache interceptor produced [res] locally (a hit, or the
/// synthetic 504 of a `cacheOnly` miss). Such a response says nothing about
/// the origin, so it must not be retried, re-cached, or counted towards
/// origin health. A real origin could echo the header and be treated the same
/// way, which is accepted.
bool isCacheFabricated(AdapterResponse res) =>
    headerValue(res.headers, cacheHitHeader) != null;

/// `InterceptedRequest.extra` key under which the auth interceptor records the
/// name of the header it wrote the token to. Anything that persists or prints
/// request headers uses it to leave the credential out, whatever the header
/// is configured to be called.
final Object credentialHeaderKey = Object();

/// Whether header [name] of [req] carries a credential: `Authorization`, or
/// the header the auth interceptor wrote the token to.
bool isCredentialHeader(InterceptedRequest req, String name) {
  final lower = name.toLowerCase();
  final configured = req.extra[credentialHeaderKey];
  return lower == 'authorization' ||
      (configured is String && configured.toLowerCase() == lower);
}
