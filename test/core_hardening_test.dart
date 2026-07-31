import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

InterceptedRequest _req(String endpoint, {CancelToken? token}) =>
    InterceptedRequest(
      method: 'GET',
      endpoint: endpoint,
      headers: {},
      options: RequestOptions(cancelToken: token),
    );

AdapterResponse _ok() => AdapterResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      bodyBytes: _b('{}'),
    );

void main() {
  group('CacheInterceptor — TTL measured from origin fetch', () {
    test('a cache hit does not rewrite the entry (no sliding TTL)', () async {
      final store = _CountingCacheStore();
      final mock = MockAdapter();
      mock.on('GET', RegExp(r'/config$'), statusCode: 200, body: {'v': 1});
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          CacheInterceptor(
            store: store,
            defaultPolicy: CachePolicy.cacheFirst(),
          ),
        ],
      ));

      await client.get<dynamic>('config');
      expect(store.writes, 1);

      final second = await client.get<dynamic>('config');
      expect(second.isSuccess, true);
      expect(mock.received, hasLength(1),
          reason: 'second call must be served from cache');
      expect(store.writes, 1,
          reason: 'a hit must not refresh savedAt (sliding TTL)');
    });

    test('a 304 whose entry was evicted mid-flight re-fetches the full body',
        () async {
      final store = _CountingCacheStore()
        // First GET: onRequest read (#1 miss), write. Second GET: onRequest
        // read (#2 → stale entry, sends If-None-Match), transport 304, then
        // onResponse read (#3) simulates the entry evicted mid-flight.
        ..nullOnReads.add(3);
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/doc$'), (req) async {
        final conditional = req.headers.keys
            .any((k) => k.toLowerCase() == 'if-none-match');
        if (conditional) {
          return AdapterResponse(
            statusCode: 304,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {
            'content-type': 'application/json',
            'etag': '"v1"',
          },
          bodyBytes: _b('{"doc":true}'),
        );
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          CacheInterceptor(
            store: store,
            defaultPolicy: CachePolicy.cacheFirst(ttl: Duration.zero),
          ),
        ],
      ));

      final first = await client.get<dynamic>('doc');
      expect(first.isSuccess, true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final second = await client.get<dynamic>('doc');
      expect(second.isSuccess, true,
          reason: 'a bare 304 with no cache entry must re-fetch, not fail');
      expect(second.statusCode, 200);
      // initial + conditional (304) + unconditional re-fetch
      expect(mock.received, hasLength(3));
      final refetch = mock.received.last;
      expect(
        refetch.headers.keys.any((k) => k.toLowerCase() == 'if-none-match'),
        isFalse,
        reason: 're-fetch must drop the stale validator',
      );
    });

    test('capitalised ETag response header still enables revalidation',
        () async {
      final store = _CountingCacheStore();
      var conditionalSeen = false;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/tagged$'), (req) async {
        final inm = req.headers.entries
            .where((e) => e.key.toLowerCase() == 'if-none-match')
            .map((e) => e.value)
            .firstOrNull;
        if (inm == '"v1"') {
          conditionalSeen = true;
          return AdapterResponse(
            statusCode: 304,
            headers: const {},
            bodyBytes: Uint8List(0),
          );
        }
        return AdapterResponse(
          statusCode: 200,
          headers: const {
            'content-type': 'application/json',
            'ETag': '"v1"',
          },
          bodyBytes: _b('{"tagged":1}'),
        );
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          CacheInterceptor(
            store: store,
            defaultPolicy: CachePolicy.cacheFirst(ttl: Duration.zero),
          ),
        ],
      ));

      await client.get<dynamic>('tagged');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await client.get<dynamic>('tagged');

      expect(conditionalSeen, isTrue,
          reason: 'the ETag stored from a capitalised header must be sent '
              'back as If-None-Match');
      expect(second.isSuccess, true);
      expect(second.statusCode, 200, reason: '304 serves the cached body');
    });

    test('a cacheOnly miss fails fast instead of being retried with backoff',
        () async {
      final mock = MockAdapter();
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          RetryInterceptor(
            policy: RetryPolicy(
              baseDelay: const Duration(seconds: 10),
              useJitter: false,
            ),
          ),
          CacheInterceptor(store: _CountingCacheStore()),
        ],
      ));

      final sw = Stopwatch()..start();
      final result = await client.get<dynamic>(
        'missing',
        options: RequestOptions(cachePolicy: CachePolicy.cacheOnly()),
      );
      sw.stop();

      expect(result.isSuccess, false);
      expect(result.statusCode, 504);
      expect(mock.received, isEmpty, reason: 'cacheOnly never hits network');
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'the synthetic 504 must not go through retry backoff');
    });
  });

  group('RetryPolicy — header casing', () {
    test('capitalised Retry-After is honoured over exponential backoff',
        () async {
      var calls = 0;
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/flaky$'), (_) async {
        calls++;
        if (calls == 1) {
          return AdapterResponse(
            statusCode: 503,
            headers: const {'Retry-After': '0'},
            bodyBytes: Uint8List(0),
          );
        }
        return _ok();
      });
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          RetryInterceptor(
            policy: RetryPolicy(
              baseDelay: const Duration(seconds: 20),
              useJitter: false,
            ),
          ),
        ],
      ));

      final sw = Stopwatch()..start();
      final result = await client.get<dynamic>('flaky');
      sw.stop();

      expect(result.isSuccess, true);
      expect(calls, 2);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'Retry-After: 0 must beat the 20s exponential backoff');
    });
  });

  group('InterceptorChain — resource safety', () {
    test('a streamed response discarded by a chain restart is drained',
        () async {
      var listened = false;
      var calls = 0;
      Future<AdapterResponse> transport(InterceptedRequest req) async {
        calls++;
        if (calls == 1) {
          final controller = StreamController<List<int>>(
            onListen: () => listened = true,
          );
          controller
            ..add([1, 2, 3])
            ..close();
          return AdapterResponse(
            statusCode: 503,
            headers: const {},
            bodyBytes: Uint8List(0),
            bodyStream: controller.stream,
          );
        }
        return _ok();
      }

      final chain = InterceptorChain([_RetryOnceOn503()]);
      final res = await chain.run(request: _req('/big'), transport: transport);

      expect(res.statusCode, 200);
      expect(listened, isTrue,
          reason: 'the discarded streamed body must be drained so the '
              'adapter can release its client');
    });

    test('depth-exceeded still lets interceptors clean up (dedup released)',
        () async {
      final dedup = DedupInterceptor();
      final chain = InterceptorChain([dedup, _AlwaysProceed()]);
      Future<AdapterResponse> transport(InterceptedRequest req) async => _ok();

      await expectLater(
        chain.run(request: _req('/loop'), transport: transport),
        throwsA(isA<UnknownError>()),
      );

      // Before the fix the first run left a dead leader in dedup's in-flight
      // map, so this second identical request stalled for the full 30s
      // waitTimeout before proceeding.
      final sw = Stopwatch()..start();
      await expectLater(
        chain.run(request: _req('/loop'), transport: transport),
        throwsA(isA<UnknownError>()),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the dedup entry from the first run must have been released');
    });
  });

  group('DedupInterceptor — cancellation isolation', () {
    test('a cancelled leader does not fail innocent followers', () async {
      final chain = InterceptorChain([DedupInterceptor()]);
      var calls = 0;
      final leaderGate = Completer<void>();
      Future<AdapterResponse> transport(InterceptedRequest req) async {
        calls++;
        if (calls == 1) {
          await leaderGate.future;
          throw const CancelError();
        }
        return _ok();
      }

      final leaderOutcome = chain
          .run(request: _req('/feed'), transport: transport)
          .then<Object>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(Duration.zero);
      final followerFuture =
          chain.run(request: _req('/feed'), transport: transport);
      await Future<void>.delayed(Duration.zero);
      leaderGate.complete();

      expect(await leaderOutcome, isA<CancelError>());
      final follower = await followerFuture;
      expect(follower.statusCode, 200,
          reason: "the follower's own token was never cancelled, so it must "
              'fall back to its own request');
      expect(calls, 2);
    });

    test('a follower whose own token fires stops waiting promptly', () async {
      final chain = InterceptorChain([DedupInterceptor()]);
      final leaderGate = Completer<AdapterResponse>();
      Future<AdapterResponse> transport(InterceptedRequest req) =>
          leaderGate.future;

      final leaderFuture =
          chain.run(request: _req('/slow'), transport: transport);
      await Future<void>.delayed(Duration.zero);

      final token = CancelToken();
      final sw = Stopwatch()..start();
      final followerFuture = chain.run(
        request: _req('/slow', token: token),
        transport: transport,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel('user left the screen');

      await expectLater(followerFuture, throwsA(isA<CancelError>()));
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the follower must not block on the leader or waitTimeout');

      leaderGate.complete(_ok());
      final leader = await leaderFuture;
      expect(leader.statusCode, 200, reason: 'the leader is undisturbed');
    });
  });

  group('CachedTokenStorage — background write safety', () {
    test('clear flushes pending writes so a token cannot be resurrected',
        () async {
      final delegate = _SlowTokenStorage();
      final cached = CachedTokenStorage(delegate);

      await cached.setAccessToken('fresh-token');
      // The delegate write is still in flight here; before the fix, clear()
      // could be overtaken and the token landed on disk after logout.
      await cached.clear();

      expect(delegate.accessToken, isNull,
          reason: 'the pending write must land before the delegate clear');
      expect(await cached.getAccessToken(), isNull);
    });

    test('a failing delegate write is reported, not an unhandled zone error',
        () async {
      Object? reported;
      final cached = CachedTokenStorage(
        _ThrowingTokenStorage(),
        onWriteError: (e, st) => reported = e,
      );

      await cached.setAccessToken('doomed');
      expect(await cached.getAccessToken(), 'doomed',
          reason: 'the cache still serves the value synchronously');
      await cached.clear();

      expect(reported, isA<StateError>(),
          reason: 'the background write failure must reach onWriteError');
    });
  });

  group('DefaultHttpAdapter — body read deadline', () {
    test('a stalled response body surfaces TimeoutError instead of hanging',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        // ignore: close_sinks — the stall IS the scenario under test.
        final res = req.response;
        res.bufferOutput = false;
        res.statusCode = 200;
        res.headers.contentType = ContentType.json;
        res.contentLength = 1024; // promise more bytes than we ever send
        res.add(utf8.encode('{"partial":'));
        await res.flush();
        // ...and stall forever: never write the rest, never close.
      });
      addTearDown(() => server.close(force: true));

      final adapter = DefaultHttpAdapter();
      await expectLater(
        adapter.send(AdapterRequest(
          method: 'GET',
          url: Uri.parse('http://127.0.0.1:${server.port}/stall'),
          headers: const {},
          timeout: const Duration(milliseconds: 400),
        )),
        throwsA(isA<TimeoutError>()),
      );
    });
  });

  group('ResponseHandler — configured charset', () {
    test('error messages decode with the configured charset', () async {
      final mock = MockAdapter();
      mock.on(
        'POST',
        RegExp(r'/fermer$'),
        statusCode: 400,
        body: latin1.encode('{"message":"Café fermé"}'),
      );
      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        charset: const _Latin1Charset(),
      ));

      final result = await client.post<dynamic>('fermer', {'a': 1});

      expect(result.error, isA<HttpError>());
      expect(result.error!.message, 'Café fermé',
          reason: 'the Latin-1 body must decode with the configured charset, '
              'not hardcoded UTF-8');
    });
  });
}

/// Cache store wrapper that counts writes and can simulate eviction by
/// returning null for scripted read numbers.
class _CountingCacheStore implements CacheStore {
  final MemoryCacheStore _inner = MemoryCacheStore();
  int writes = 0;
  int reads = 0;
  final Set<int> nullOnReads = {};

  @override
  Future<CacheEntry?> read(String key) async {
    reads++;
    if (nullOnReads.contains(reads)) return null;
    return _inner.read(key);
  }

  @override
  Future<void> write(CacheEntry entry) async {
    writes++;
    await _inner.write(entry);
  }

  @override
  Future<void> delete(String key) => _inner.delete(key);

  @override
  Future<void> clear() => _inner.clear();
}

/// Restarts the chain once on a 503, mimicking a retry decision.
class _RetryOnceOn503 extends Interceptor {
  bool _retried = false;

  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async {
    if (res.statusCode == 503 && !_retried) {
      _retried = true;
      return ProceedResult(req.copy());
    }
    return ResolveResult(res);
  }
}

/// Pathological interceptor that restarts the chain on every response,
/// guaranteeing the retry-depth limit is hit.
class _AlwaysProceed extends Interceptor {
  @override
  Future<InterceptorResult> onResponse(
    InterceptedRequest req,
    AdapterResponse res,
  ) async =>
      ProceedResult(req.copy());
}

/// Token storage whose writes land after a delay, exposing write/clear races.
class _SlowTokenStorage implements TokenStorage {
  String? accessToken;
  String? refreshToken;

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<void> setAccessToken(String? token) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    accessToken = token;
  }

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> setRefreshToken(String? token) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    refreshToken = token;
  }

  @override
  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
  }
}

/// Token storage whose writes always fail (locked keystore, full disk).
class _ThrowingTokenStorage implements TokenStorage {
  @override
  Future<String?> getAccessToken() async => null;

  @override
  Future<void> setAccessToken(String? token) async {
    throw StateError('keystore locked');
  }

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<void> setRefreshToken(String? token) async {
    throw StateError('keystore locked');
  }

  @override
  Future<void> clear() async {}
}

/// Latin-1 charset for exercising configurable response decoding.
class _Latin1Charset implements Charset {
  const _Latin1Charset();

  @override
  String decode(List<int> bytes) => latin1.decode(bytes);

  @override
  List<int> encode(String s) => latin1.encode(s);
}
