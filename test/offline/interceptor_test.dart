import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A store whose writes always fail (e.g. disk full / unserializable body).
class _AlwaysThrowStore implements OfflineQueueStore {
  @override
  Future<void> enqueue(QueuedRequest request) async {
    throw StateError('disk full');
  }

  @override
  Future<List<QueuedRequest>> drain() async => const [];

  @override
  Future<void> remove(String id) async {}

  @override
  Future<int> get length async => 0;
}

void main() {
  group('OfflineQueueInterceptor', () {
    test('enqueues POST on NetworkError when offline', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'), (_) async {
        throw const NetworkError('no network');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              isOnline: () async => false,
            ),
          ],
        ),
      );

      await client.post<dynamic>('save', {'x': 1});
      expect(await store.length, 1);
      final items = await store.drain();
      expect(items.first.method, 'POST');
      expect(items.first.endpoint, 'save');
    });

    test('enqueues PUT on TimeoutError when offline', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('PUT', RegExp(r'/update$'), (_) async {
        throw const TimeoutError('timeout');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              isOnline: () async => false,
            ),
          ],
        ),
      );

      await client.put<dynamic>('update', {'v': 2});
      expect(await store.length, 1);
    });

    test('drops authorization header before persisting queued request',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/secure-save$'), (_) async {
        throw const NetworkError('offline');
      });

      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          tokenStorage: MemoryTokenStorage(accessToken: 'jwt-123'),
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              isOnline: () async => false,
            ),
          ],
        ),
      );

      await client.post<dynamic>(
        'secure-save',
        {'v': 1},
        options: const RequestOptions(headers: {'x-tenant': 'tenant-a'}),
      );

      final queued = await store.drain();
      expect(queued, hasLength(1));
      expect(queued.first.headers.containsKey('Authorization'), false);
      expect(queued.first.headers['x-tenant'], 'tenant-a');
    });

    test('a caller-supplied Authorization header is never persisted', () async {
      // The replayer re-attaches a FRESH token; persisting the stale one would
      // be both a security leak and a correctness bug. Enqueue path must strip.
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(store: store, isOnline: () async => false),
        ],
      ));
      await client.post<dynamic>('save', {'n': 1},
          options: const RequestOptions(
              headers: {'Authorization': 'Bearer SECRET'}));
      final drained = await store.drain();
      expect(drained, hasLength(1));
      final hk =
          drained.single.headers.keys.map((k) => k.toLowerCase()).toList();
      expect(hk, isNot(contains('authorization')),
          reason: 'no stale secret persisted to disk');
    });

    test('does not enqueue GET (non-mutating method)', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/read$'), (_) async {
        throw const NetworkError('no network');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              isOnline: () async => false,
            ),
          ],
        ),
      );

      await client.get<dynamic>('read');
      expect(await store.length, 0);
    });

    test('does not enqueue when isOnline returns true', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'), (_) async {
        throw const NetworkError('intermittent');
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              isOnline: () async => true,
            ),
          ],
        ),
      );

      await client.post<dynamic>('save', {});
      expect(await store.length, 0);
    });

    test('does not enqueue on HttpError (not a network failure)', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/bad$'), (_) async {
        throw const HttpError('server error', statusCode: 500);
      });

      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(
              store: store,
              isOnline: () async => false,
            ),
          ],
        ),
      );

      await client.post<dynamic>('bad', {});
      expect(await store.length, 0);
    });
  });

  group('OfflineQueueInterceptor — unique ids', () {
    test('two same-microsecond same-endpoint enqueues get distinct ids',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'), (_) async {
        throw const NetworkError('offline');
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            OfflineQueueInterceptor(store: store, isOnline: () async => false),
          ],
        ),
      );

      // Two identical mutations back-to-back: colliding ids would make the
      // second overwrite the first in a keyed store.
      await client.post<dynamic>('save', {'n': 1});
      await client.post<dynamic>('save', {'n': 2});

      final drained = await store.drain();
      expect(drained, hasLength(2), reason: 'no write may be lost');
      final ids = drained.map((e) => e.id).toSet();
      expect(ids, hasLength(2), reason: 'ids must be unique');
    });
  });

  group('OfflineQueueInterceptor — capture fidelity', () {
    test('queued record preserves queryParameters and baseUrlOverride',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(store: store, isOnline: () async => false),
        ],
      ));

      await client.post<dynamic>(
        'save',
        {'v': 1},
        options: const RequestOptions(
          queryParameters: {'draft': true, 'rev': 7},
          baseUrlOverride: 'https://tenant.example.com',
        ),
      );

      final queued = (await store.peekAll()).single;
      expect(queued.queryParameters, {'draft': true, 'rev': 7});
      expect(queued.baseUrlOverride, 'https://tenant.example.com');
    });

    test('multipart requests are not queued (cannot be replayed faithfully)',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/upload$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(store: store, isOnline: () async => false),
        ],
      ));

      final result = await client.post<dynamic>(
        'upload',
        {'file': 'x'},
        isMultipart: true,
      );

      expect(result.isSuccess, false);
      expect(await store.length, 0);
    });

    test('a throwing store does not mask the original network error', () async {
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(
            store: _AlwaysThrowStore(),
            isOnline: () async => false,
          ),
        ],
      ));

      final result = await client.post<dynamic>('save', {'v': 1});
      expect(result.error, isA<NetworkError>(),
          reason: 'the enqueue failure must not replace the network error');
    });

    test('onQueued fires with the stored record', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      QueuedRequest? seen;
      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(
            store: store,
            isOnline: () async => false,
            onQueued: (q) => seen = q,
          ),
        ],
      ));

      await client.post<dynamic>('save', {'v': 1});
      expect(seen, isNotNull);
      expect(seen!.endpoint, 'save');
      expect(await store.length, 1);
    });

    test('a throwing onQueued listener does not mask the network error',
        () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter();
      mock.onRequest('POST', RegExp(r'/save$'),
          (_) async => throw const NetworkError('offline'));

      final client = ApiClient(ApiClientConfig.test(
        baseUrl: 'https://api.example.com',
        adapter: mock,
        interceptors: [
          OfflineQueueInterceptor(
            store: store,
            isOnline: () async => false,
            onQueued: (_) => throw StateError('listener bug'),
          ),
        ],
      ));

      final result = await client.post<dynamic>('save', {'v': 1});
      expect(result.error, isA<NetworkError>());
      expect(await store.length, 1, reason: 'request still queued');
    });
  });

  group('credentials and includeToken', () {
    ApiClient offlineClient(
      OfflineQueueStore store,
      MockAdapter mock, {
      required bool online,
    }) =>
        ApiClient(ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          tokenStorage: MemoryTokenStorage(accessToken: 'secret-token'),
          authHeaderName: 'X-Session',
          interceptors: [
            OfflineQueueInterceptor(store: store, isOnline: () async => online),
          ],
        ));

    test('a custom-named auth header is never persisted', () async {
      final store = InMemoryOfflineQueueStore();
      final mock = MockAdapter()
        ..onRequest('POST', RegExp(r'/todos$'),
            (_) async => throw const NetworkError('offline'));

      await offlineClient(store, mock, online: false)
          .post<dynamic>('todos', {'t': 1});

      final queued = (await store.peekAll()).single;
      expect(queued.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-session')));
    });

    test('a request sent without the token is replayed without it', () async {
      final store = InMemoryOfflineQueueStore();
      var offline = true;
      final mock = MockAdapter()
        ..onRequest('POST', RegExp(r'/public$'), (_) async {
          if (offline) throw const NetworkError('offline');
          return AdapterResponse(
              statusCode: 200, headers: const {}, bodyBytes: Uint8List(0));
        });
      final client = offlineClient(store, mock, online: false);

      await client.post<dynamic>('public', {'t': 1}, includeToken: false);
      offline = false;
      final report =
          await OfflineQueueReplayer(store: store, client: client).replay();

      expect(report.succeeded, 1);
      expect(mock.received.last.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-session')));
    });

    test('includeToken survives a JSON round trip', () {
      final request = QueuedRequest(
        id: 'a',
        method: 'POST',
        endpoint: 'public',
        headers: const {},
        createdAt: DateTime(2025),
        includeToken: false,
      );
      expect(QueuedRequest.fromJson(request.toJson()).includeToken, isFalse);
      expect(
        QueuedRequest.fromJson(request.toJson()..remove('includeToken'))
            .includeToken,
        isTrue,
        reason: 'records written before the field existed attach the token',
      );
    });
  });
}
