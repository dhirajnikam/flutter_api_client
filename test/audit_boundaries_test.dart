// ARCHITECTURE BOUNDARIES + EXTENSIBILITY + CONTRACTS audit (work item w4).
//
// Lens: Barbara Liskov — substitutability. A documented extension point is only
// real if ANY conforming implementation can be dropped in wherever the
// interface is expected and the client keeps behaving correctly, without the
// client reaching behind the interface for a concrete type.
//
// Each group below defines a BESPOKE implementation of one published interface
// (HttpAdapter, StreamingHttpAdapter, TokenStorage, CacheStore,
// OfflineQueueStore, ResponseHandlerInterface, RetryPolicyInterface /
// CachePolicyInterface, Interceptor) — written here in the test, with no
// knowledge of the package's own concrete classes — and proves it drives the
// real ApiClient/InterceptorChain end to end.
//
// These tests also encode the layering contract: spec/graphql/gen sit ON core
// and substitute through core's published seams; core never depends back on
// them.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
// cli_helpers are an INTERNAL gen-layer surface (deliberately not re-exported
// from the public library), imported here by package path to audit their
// platform-independence contract — the same seam the bundled gen CLI uses.
import 'package:flutter_api_client/src/gen/cli_helpers.dart';
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

// A custom RetryPolicyInterface marker carried through RequestOptions, proving
// the dependency-inverted marker contract in core/policies.dart actually flows.
class _MyRetryPolicy implements RetryPolicyInterface {
  const _MyRetryPolicy();
}

class _MyCachePolicy implements CachePolicyInterface {
  const _MyCachePolicy();
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
      // The client exposes the configured adapter identically regardless of
      // which concrete implementation was supplied.
      expect(identical(client.adapter, adapter), isTrue);
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
      // The queued mutation must NOT carry the Authorization header.
      expect(
        q.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
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
    test('a custom Interceptor composes with built-ins in order', () async {
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

  group('Dependency inversion: core marker policies', () {
    test(
        'custom RetryPolicyInterface / CachePolicyInterface flow through '
        'RequestOptions without core depending on interceptors', () {
      // core/policies.dart declares these marker interfaces so RequestOptions
      // can carry a policy with a real type. A bespoke implementation must be
      // assignable — proving the inversion is genuine, not a concrete coupling.
      const options = RequestOptions(
        retryPolicy: _MyRetryPolicy(),
        cachePolicy: _MyCachePolicy(),
      );
      expect(options.retryPolicy, isA<RetryPolicyInterface>());
      expect(options.cachePolicy, isA<CachePolicyInterface>());

      // The concrete library policies implement the same markers — substitution
      // is bidirectional.
      const RetryPolicyInterface concreteRetry = _MyRetryPolicy();
      expect(concreteRetry, isA<RetryPolicyInterface>());
      final libRetry = RetryPolicy();
      expect(libRetry, isA<RetryPolicyInterface>());
      final libCache = CachePolicy.cacheFirst();
      expect(libCache, isA<CachePolicyInterface>());
    });

    test(
        'CacheInterceptor honours a per-request CachePolicy override via the '
        'core marker type', () async {
      var hits = 0;
      final adapter = _ScriptedAdapter((req) {
        hits++;
        return _json(200, {'v': hits});
      });
      final store = MemoryCacheStore();
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://x.test',
          adapter: adapter,
          interceptors: [CacheInterceptor(store: store)],
        ),
      );
      // No defaultPolicy; the per-request CachePolicy (typed as the core
      // marker on RequestOptions) is what activates caching.
      final opts = RequestOptions(cachePolicy: CachePolicy.cacheFirst());
      await client.get<Map<String, dynamic>>('x', options: opts);
      await client.get<Map<String, dynamic>>('x', options: opts);
      expect(hits, 1);
    });
  });

  group('Layering: spec/graphql/gen sit ON core via published seams', () {
    test('SpecMockAdapter substitutes as an HttpAdapter and validates bodies',
        () async {
      final spec = ApiSpec(
        title: 'T',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'POST /widgets',
        request: RequestExample(
          schema: Schema.object({
            'name': Schema.string(required: true),
          }),
        ),
        response: const ResponseExample(
          statusCode: 201,
          body: {'id': 'w1'},
        ),
      );

      // The spec subsystem plugs in WHERE an HttpAdapter is expected — proving
      // it depends on core's transport seam, not the reverse.
      final HttpAdapter adapter = SpecMockAdapter(spec);
      final client = ApiClient(
        ApiClientConfig.test(baseUrl: 'https://api.test', adapter: adapter),
      );

      final ok = await client.post<Map<String, dynamic>>(
        'widgets',
        {'name': 'gadget'},
      );
      expect(ok.statusCode, 201);
      expect(ok.data, {'id': 'w1'});

      // Missing required field -> schema validation rejects with 422.
      final bad = await client.post<Map<String, dynamic>>('widgets', {});
      expect(bad.statusCode, 422);
      expect(bad.isFailure, isTrue);
    });

    test('GraphQLClient is layered cleanly on ApiClient via SpecMockAdapter',
        () async {
      final spec = ApiSpec(
        title: 'G',
        version: '1.0.0',
        baseUrl: 'https://api.test',
      );
      spec.graphql((g) {
        g.query(
          'Me',
          document: 'query Me { me { id name } }',
          responseExample: {
            'me': {'id': '1', 'name': 'Ada'}
          },
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.test',
          adapter: SpecMockAdapter(spec),
        ),
      );
      final gql = GraphQLClient(client);
      final res = await gql.query<Map<String, dynamic>>(
        'query Me { me { id name } }',
      );
      expect(res.isSuccess, isTrue);
      expect(res.data, {
        'me': {'id': '1', 'name': 'Ada'}
      });
      expect(res.errors, isEmpty);
    });

    test('gen cli_helpers stay platform-independent (forward-slash contract)',
        () {
      // The gen layer is a pure helper over file paths; its published contract
      // is forward-slash normalization regardless of host separators.
      final import = packageImportFromLibPath(
        'flutter_api_client',
        'lib\\src\\spec\\api_spec.dart',
      );
      expect(import, 'package:flutter_api_client/src/spec/api_spec.dart');

      final only = parseOnly('openapi,tests');
      expect(only, ['openapi', 'tests']);
      expect(() => parseOnly('bogus'), throwsArgumentError);
    });

    test('OpenApiGenerator round-trips a spec into a 3.1 document', () {
      final spec = ApiSpec(
        title: 'Docs',
        version: '2.0.0',
        baseUrl: 'https://api.test',
      );
      spec.endpoint(
        'GET /ping',
        response: const ResponseExample(statusCode: 200, body: {'pong': true}),
      );
      final doc = OpenApiGenerator(spec).toJson();
      expect(doc['openapi'], '3.1.0');
      expect((doc['paths'] as Map).containsKey('/ping'), isTrue);
      // Generator output must be valid JSON (serializable) — contract for docs.
      expect(() => jsonEncode(doc), returnsNormally);
    });
  });

  group('Schema validation contract (spec subsystem)', () {
    test('nested object + array validation returns precise error paths', () {
      final schema = Schema.object({
        'user': Schema.object({
          'name': Schema.string(required: true, minLength: 2),
          'tags': Schema.array(Schema.string()),
        }),
      });
      final errors = schema.validate({
        'user': {
          'name': 'a', // too short
          'tags': ['ok', 123], // wrong element type
        },
      });
      expect(errors, isNotEmpty);
      expect(errors.any((e) => e.contains('minLength')), isTrue);
      expect(errors.any((e) => e.contains('tags[1]')), isTrue);
    });
  });
}
