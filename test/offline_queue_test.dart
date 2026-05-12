import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemoryOfflineQueueStore', () {
    test('enqueue adds item and length reflects it', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(
        QueuedRequest(
          id: '1',
          method: 'POST',
          endpoint: '/items',
          headers: const {},
          createdAt: DateTime(2024),
        ),
      );
      expect(await store.length, 1);
    });

    test('drain returns all items and empties store', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(
        QueuedRequest(
            id: 'a',
            method: 'POST',
            endpoint: '/a',
            headers: const {},
            createdAt: DateTime(2024)),
      );
      await store.enqueue(
        QueuedRequest(
            id: 'b',
            method: 'PUT',
            endpoint: '/b',
            headers: const {},
            createdAt: DateTime(2024)),
      );
      final drained = await store.drain();
      expect(drained, hasLength(2));
      expect(await store.length, 0);
    });

    test('remove deletes item by id', () async {
      final store = InMemoryOfflineQueueStore();
      await store.enqueue(
        QueuedRequest(
            id: 'x',
            method: 'DELETE',
            endpoint: '/x',
            headers: const {},
            createdAt: DateTime(2024)),
      );
      await store.remove('x');
      expect(await store.length, 0);
    });

    test('QueuedRequest.toJson serialises correctly', () {
      final req = QueuedRequest(
        id: '42',
        method: 'PATCH',
        endpoint: '/thing',
        headers: const {'x-foo': 'bar'},
        body: {'key': 'val'},
        createdAt: DateTime(2024, 1, 15),
      );
      final json = req.toJson();
      expect(json['id'], '42');
      expect(json['method'], 'PATCH');
      expect(json['endpoint'], '/thing');
      expect(json['headers'], {'x-foo': 'bar'});
      expect(json['body'], {'key': 'val'});
      expect(json['createdAt'], contains('2024-01-15'));
    });
  });

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
}
