// Each group defines a from-scratch implementation of one published extension
// point and drives the real ApiClient with it, so the client is proven to depend
// only on the interface, never on the package's own concrete classes.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Bespoke HttpAdapter — a transport substitute with ZERO ties to MockAdapter /
// DefaultHttpAdapter. Records calls and replays scripted responses.
// ---------------------------------------------------------------------------
class _ScriptedAdapter implements HttpAdapter {
  _ScriptedAdapter(this._script);

  final AdapterResponse Function(AdapterRequest req) _script;
  final List<AdapterRequest> seen = [];
  int closed = 0;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    seen.add(request);
    return _script(request);
  }

  @override
  void close() => closed++;
}

// A transport that THROWS a typed transport error (network down), to prove the
// chain treats a custom adapter's failures exactly like the built-in one's.
class _FailingAdapter implements HttpAdapter {
  _FailingAdapter(this.error);
  final ApiException error;
  int calls = 0;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    calls++;
    throw error;
  }

  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// Bespoke StreamingHttpAdapter — proves the OPTIONAL capability interface is
// honoured by ApiClient.stream() purely via the published seam, and that an
// adapter NOT implementing it falls back to buffering.
// ---------------------------------------------------------------------------
class _StreamingAdapter implements HttpAdapter, StreamingHttpAdapter {
  bool streamedCalled = false;
  bool sendCalled = false;

  @override
  Future<AdapterResponse> send(AdapterRequest request) async {
    sendCalled = true;
    return AdapterResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/octet-stream'},
      bodyBytes: Uint8List.fromList([1, 2, 3]),
    );
  }

  @override
  Future<AdapterResponse> sendStreaming(AdapterRequest request) async {
    streamedCalled = true;
    return AdapterResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/octet-stream'},
      bodyBytes: Uint8List(0),
      bodyStream: Stream<List<int>>.fromIterable([
        [104, 105], // "hi"
        [33], // "!"
      ]),
    );
  }

  @override
  void close() {}
}

// A non-streaming adapter (only implements the base interface) — stream()
// must still work via the buffering fallback path.
class _NonStreamingAdapter implements HttpAdapter {
  @override
  Future<AdapterResponse> send(AdapterRequest request) async => AdapterResponse(
        statusCode: 200,
        headers: const {'content-type': 'text/plain'},
        bodyBytes: Uint8List.fromList(utf8.encode('buffered')),
      );

  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// Bespoke TokenStorage — backed by an external sink (simulating SecureStorage)
// with NO inheritance from MemoryTokenStorage. Proves AuthInterceptor depends
// only on the abstract contract, including the default-method behaviour of the
// abstract base (getRefreshToken / clear).
// ---------------------------------------------------------------------------
class _VaultTokenStorage extends TokenStorage {
  _VaultTokenStorage(this._vault);
  final Map<String, String?> _vault;

  @override
  Future<String?> getAccessToken() async => _vault['access'];

  @override
  Future<void> setAccessToken(String? token) async => _vault['access'] = token;
  // Deliberately does NOT override getRefreshToken / setRefreshToken / clear —
  // it relies on the abstract base's default implementations. If those defaults
  // were broken the substitution would leak.
}

// ---------------------------------------------------------------------------
// Bespoke CacheStore — a write-through store recording operations. No ties to
// MemoryCacheStore. Proves CacheInterceptor speaks only the CacheStore
// contract.
// ---------------------------------------------------------------------------
class _RecordingCacheStore implements CacheStore {
  final Map<String, CacheEntry> _data = {};
  final List<String> ops = [];

  @override
  Future<CacheEntry?> read(String key) async {
    ops.add('read');
    return _data[key];
  }

  @override
  Future<void> write(CacheEntry entry) async {
    ops.add('write');
    _data[entry.key] = entry;
  }

  @override
  Future<void> delete(String key) async {
    ops.add('delete');
    _data.remove(key);
  }

  @override
  Future<void> clear() async {
    ops.add('clear');
    _data.clear();
  }
}

// ---------------------------------------------------------------------------
// Bespoke OfflineQueueStore — proves the offline interceptor depends only on
// the abstract store, including the QueuedRequest contract.
// ---------------------------------------------------------------------------
class _CountingQueueStore implements OfflineQueueStore {
  final List<QueuedRequest> items = [];

  @override
  Future<void> enqueue(QueuedRequest request) async => items.add(request);

  @override
  Future<List<QueuedRequest>> drain() async {
    final out = List<QueuedRequest>.from(items);
    items.clear();
    return out;
  }

  @override
  Future<void> remove(String id) async => items.removeWhere((r) => r.id == id);

  @override
  Future<int> get length async => items.length;
}

// ---------------------------------------------------------------------------
// Bespoke ResponseHandlerInterface — a custom error-message extractor.
// ---------------------------------------------------------------------------
class _ShoutingResponseHandler implements ResponseHandlerInterface {
  @override
  String? handleResponse(AdapterResponse response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return null;
    return 'CUSTOM-HANDLER: ${response.statusCode}';
  }

  @override
  bool isHtmlOrTextResponse(String responseBody) =>
      responseBody.trimLeft().startsWith('<');
}

// ---------------------------------------------------------------------------
// Bespoke Interceptor — a header-stamping interceptor proving the abstract
// Interceptor base is a clean extension point and that custom subclasses
// compose in the chain with the built-ins.
// ---------------------------------------------------------------------------
class _StampInterceptor extends Interceptor {
  const _StampInterceptor();
  @override
  Future<InterceptorResult> onRequest(InterceptedRequest req) async {
    req.headers['X-Stamp'] = 'liskov';
    return ProceedResult(req);
  }
}

AdapterResponse _json(int status, Object body,
        {Map<String, String> headers = const {}}) =>
    AdapterResponse(
      statusCode: status,
      headers: {'content-type': 'application/json', ...headers},
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );

void main() {
  group('LSP: HttpAdapter substitutability', () {
    test('a from-scratch HttpAdapter drives ApiClient.get end to end',
        () async {
      final adapter = _ScriptedAdapter(
        (req) => _json(200, {'id': 7, 'name': 'liskov'}),
      );
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );

      final res = await client.get<Map<String, dynamic>>('users/7');

      expect(res.isSuccess, isTrue);
      expect(res.data, {'id': 7, 'name': 'liskov'});
      expect(adapter.seen.single.method, 'GET');
    });

    test('client.close() forwards to the custom adapter (resource contract)',
        () async {
      final adapter = _ScriptedAdapter((req) => _json(200, const {}));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );
      client.close();
      expect(adapter.closed, 1);
    });

    test('a transport-throwing adapter surfaces as a typed Failure, no crash',
        () async {
      final adapter = _FailingAdapter(const NetworkError('socket reset'));
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );
      final res = await client.get<Map<String, dynamic>>('thing');
      expect(res.isFailure, isTrue);
      expect(res.error, isA<NetworkError>());
    });
  });

  group('LSP: StreamingHttpAdapter optional capability', () {
    test('ApiClient.stream uses sendStreaming when the adapter provides it',
        () async {
      final adapter = _StreamingAdapter();
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );
      final res = await client.stream('download');
      expect(res.isSuccess, isTrue);
      final body = await res.data!.stream
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      expect(utf8.decode(body), 'hi!');
      expect(adapter.streamedCalled, isTrue);
      expect(adapter.sendCalled, isFalse);
    });

    test('stream() falls back to buffering when adapter lacks the capability',
        () async {
      final adapter = _NonStreamingAdapter();
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://x.test', adapter: adapter),
      );
      final res = await client.stream('download');
      expect(res.isSuccess, isTrue);
      final body = await res.data!.stream
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      expect(utf8.decode(body), 'buffered');
    });
  });

  group('LSP: TokenStorage substitutability (incl. abstract defaults)', () {
    test('a custom TokenStorage injects the Authorization header', () async {
      final vault = <String, String?>{'access': 'tok-123'};
      final adapter = _ScriptedAdapter((req) => _json(200, const {'ok': true}));
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://x.test',
          tokenStorage: _VaultTokenStorage(vault),
          adapter: adapter,
        ),
      );
      final res = await client.get<Map<String, dynamic>>('me');
      expect(res.isSuccess, isTrue);
      expect(adapter.seen.single.headers['Authorization'], 'Bearer tok-123');
    });

    test('abstract TokenStorage default getRefreshToken/clear are usable',
        () async {
      final storage = _VaultTokenStorage(<String, String?>{'access': 'a'});
      // These rely entirely on the abstract base's default implementations.
      expect(await storage.getRefreshToken(), isNull);
      await storage.clear(); // default clear() nulls access via setAccessToken
      expect(await storage.getAccessToken(), isNull);
    });

    test('CachedTokenStorage substitutes for TokenStorage transparently',
        () async {
      final delegate = MemoryTokenStorage(accessToken: 'seed');
      final TokenStorage cached = CachedTokenStorage(delegate);
      expect(await cached.getAccessToken(), 'seed');
      await cached.setAccessToken('updated');
      expect(await cached.getAccessToken(), 'updated');
      // Background write-through reaches the delegate.
      await Future<void>.delayed(Duration.zero);
      expect(await delegate.getAccessToken(), 'updated');
      await cached.clear();
      expect(await cached.getAccessToken(), isNull);
      expect(await delegate.getAccessToken(), isNull);
    });
  });

  group('LSP: CacheStore substitutability', () {
    test('a custom CacheStore is read and written by CacheInterceptor',
        () async {
      var hits = 0;
      final adapter = _ScriptedAdapter((req) {
        hits++;
        return _json(200, {'v': hits});
      });
      final store = _RecordingCacheStore();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: adapter,
          interceptors: [
            CacheInterceptor(
              store: store,
              defaultPolicy: CachePolicy.cacheFirst(),
            ),
          ],
        ),
      );

      final first = await client.get<Map<String, dynamic>>('data');
      expect(first.data, {'v': 1});
      // Second call should be served from the custom store, NOT the network.
      final second = await client.get<Map<String, dynamic>>('data');
      expect(second.data, {'v': 1});
      expect(hits, 1, reason: 'cacheFirst must serve the custom store');
      expect(store.ops, contains('write'));
      expect(store.ops, contains('read'));
    });
  });

  group('LSP: OfflineQueueStore substitutability', () {
    test('a custom queue store captures a failed mutation while offline',
        () async {
      final adapter = _FailingAdapter(const NetworkError('offline'));
      final store = _CountingQueueStore();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: adapter,
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              isOnline: () async => false,
            ),
          ],
        ),
      );
      final res = await client.post<Map<String, dynamic>>('orders', {'q': 1});
      expect(res.isFailure, isTrue);
      expect(await store.length, 1);
      final q = store.items.single;
      expect(q.method, 'POST');
      expect(q.endpoint, 'orders');
    });
  });

  group('LSP: ResponseHandlerInterface substitutability', () {
    test('a custom response handler shapes the error message', () async {
      final adapter = _ScriptedAdapter(
        (req) => _json(500, {'message': 'ignored by custom handler'}),
      );
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://x.test',
          adapter: adapter,
          responseHandler: _ShoutingResponseHandler(),
        ),
      );
      final res = await client.get<Map<String, dynamic>>('boom');
      expect(res.isFailure, isTrue);
      expect(res.errorMessage, 'CUSTOM-HANDLER: 500');
    });
  });

  group('LSP: Interceptor substitutability + composition', () {
    test('a custom Interceptor can modify the outgoing request', () async {
      final adapter = _ScriptedAdapter((req) => _json(200, const {'ok': true}));
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: adapter,
          interceptors: const [_StampInterceptor()],
        ),
      );
      await client.get<Map<String, dynamic>>('thing');
      expect(adapter.seen.single.headers['X-Stamp'], 'liskov');
    });
  });
}
