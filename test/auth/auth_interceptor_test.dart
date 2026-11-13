import 'dart:typed_data';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart' hide within;

import '../support/liveness.dart';

InterceptedRequest _req({
  String method = 'GET',
  String endpoint = '/x',
  Map<String, String>? headers,
  Object? data,
}) =>
    InterceptedRequest(
      method: method,
      endpoint: endpoint,
      headers: headers ?? <String, String>{},
      options: const RequestOptions(),
      data: data,
    );

/// A request that has been through [auth]'s `onRequest`, i.e. went out with
/// whatever token the storage held at that moment.
Future<InterceptedRequest> _sentWith(AuthInterceptor auth) async {
  final req = _req();
  await auth.onRequest(req);
  return req;
}

/// TokenStorage whose getAccessToken can be made to interleave: each call
/// awaits a microtask, widening the window in which two concurrent flows can
/// observe the same pre-refresh state. Used to stress the single-flight guard.
class _SlowTokenStorage implements TokenStorage {
  _SlowTokenStorage(this._token);
  String? _token;
  int reads = 0;

  @override
  Future<String?> getAccessToken() async {
    reads++;
    await Future<void>.delayed(Duration.zero);
    return _token;
  }

  @override
  Future<void> setAccessToken(String? token) async => _token = token;
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<void> clear() async => _token = null;
}

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  // ===========================================================================
  // Auth single-flight refresh.
  //   For any set of concurrent 401s observed within one refresh generation,
  //   the user-supplied `refresh` callback is invoked AT MOST ONCE, and every
  //   waiter observes the same outcome. (No double-refresh, no lost wakeup.)
  // ===========================================================================
  group('auth refresh is single-flight', () {
    test('N concurrent 401s trigger exactly one refresh', () async {
      var refreshCalls = 0;
      final storage = _SlowTokenStorage('OLD');
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          // A slow refresh: all concurrent callers MUST coalesce onto this one
          // future, not each start their own.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await storage.setAccessToken('FRESH');
          return true;
        },
      );

      AdapterResponse res401() => AdapterResponse(
            statusCode: 401,
            headers: const {},
            bodyBytes: Uint8List(0),
          );

      // Eight requests all went out with the same token and all get 401 at
      // once. The stored token still equals what they used, so every one of
      // them wants a refresh — which must collapse to a single refresh().
      final sent = [for (var i = 0; i < 8; i++) await _sentWith(auth)];
      final futures = sent.map((r) => auth.onResponse(r, res401()));

      final results = await within(Future.wait(futures));
      // Postcondition 1: every waiter proceeds to retry.
      for (final r in results) {
        expect(r, isA<ProceedResult>());
      }
      // Postcondition 2: exactly one refresh fired for the whole cohort.
      expect(refreshCalls, 1, reason: 'single-flight: at most one refresh');
    });

    test('a second generation refreshes again (guard resets after completion)',
        () async {
      var refreshCalls = 0;
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          // Do NOT rotate the token, so the staleness guard never fires and
          // the second generation genuinely needs its own refresh.
          return true;
        },
      );
      AdapterResponse res401() => AdapterResponse(
          statusCode: 401, headers: const {}, bodyBytes: Uint8List(0));

      await within(auth.onResponse(await _sentWith(auth), res401()));
      await within(auth.onResponse(await _sentWith(auth), res401()));

      expect(refreshCalls, 2, reason: 'guard must reset after each generation');
    });

    test('a failing refresh does not wedge later refreshes', () async {
      var refreshCalls = 0;
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          throw const NetworkError('refresh endpoint down');
        },
      );
      AdapterResponse res401() => AdapterResponse(
          statusCode: 401, headers: const {}, bodyBytes: Uint8List(0));

      // First generation: refresh throws, so the 401 is surfaced as-is.
      final r1 = await within(auth.onResponse(await _sentWith(auth), res401()));
      expect(r1, isA<ResolveResult>(), reason: 'failed refresh surfaces 401');

      // Second generation must be able to TRY AGAIN — proof the latch released
      // even on the exceptional path.
      final r2 = await within(auth.onResponse(await _sentWith(auth), res401()));
      expect(r2, isA<ResolveResult>());
      expect(refreshCalls, 2, reason: 'latch released on the failure path too');
    });
  });

  group('AuthInterceptor — concurrent 401 staleness guard', () {
    test('does not refresh again when token already rotated', () async {
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      var refreshCalls = 0;
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          await storage.setAccessToken('NEWER');
          return true;
        },
      );

      // Simulate a request that went out with OLD, but storage already holds
      // NEW (rotated by a concurrent flow) by the time the 401 comes back.
      final req = await _sentWith(auth);
      await storage.setAccessToken('NEW'); // rotated under us

      final res = AdapterResponse(
        statusCode: 401,
        headers: const {},
        bodyBytes: Uint8List(0),
      );
      final r = await auth.onResponse(req, res);

      // Must retry (ProceedResult) WITHOUT triggering another refresh.
      expect(r, isA<ProceedResult>());
      expect(refreshCalls, 0, reason: 'no redundant refresh');
      final retry = (r as ProceedResult).request;
      // Stale Authorization dropped so onRequest re-attaches the fresh token.
      expect(retry.headers.containsKey('Authorization'), isFalse);
    });

    test('refreshes once when token is still the one we used', () async {
      final storage = MemoryTokenStorage(accessToken: 'OLD');
      var refreshCalls = 0;
      final auth = AuthInterceptor(
        storage: storage,
        refresh: () async {
          refreshCalls++;
          await storage.setAccessToken('FRESH');
          return true;
        },
      );
      final req = await _sentWith(auth);
      final res = AdapterResponse(
        statusCode: 401,
        headers: const {},
        bodyBytes: Uint8List(0),
      );
      final r = await auth.onResponse(req, res);
      expect(r, isA<ProceedResult>());
      expect(refreshCalls, 1);
    });
  });

  group('Auth header name', () {
    test('custom auth header name is honoured', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/x$'), statusCode: 200, body: {'ok': true});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'tok',
          authHeaderName: 'X-Auth-Token',
        ),
      );
      await client.get<dynamic>('x');
      final h = mock.received.single.headers;
      expect(h['X-Auth-Token'], 'Bearer tok');
      expect(h.containsKey('Authorization'), false);
    });
  });

  group('AuthInterceptor refresh queue', () {
    test('refreshes once for concurrent 401s', () async {
      var refreshCalls = 0;
      final storage = MemoryTokenStorage(accessToken: 'old');
      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        final auth = req.headers['Authorization'] ?? '';
        if (auth == 'Bearer new') {
          return AdapterResponse(
            statusCode: 200,
            headers: const {},
            bodyBytes: _b('{"ok":true}'),
          );
        }
        return AdapterResponse(
          statusCode: 401,
          headers: const {},
          bodyBytes: _b('{"message":"nope"}'),
        );
      });
      final client = ApiClient(
        ApiClientConfig.test(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          interceptors: [
            AuthInterceptor(
              storage: storage,
              refresh: () async {
                refreshCalls++;
                await Future<void>.delayed(const Duration(milliseconds: 10));
                await storage.setAccessToken('new');
                return true;
              },
            ),
          ],
        ),
      );
      final results = await Future.wait([
        client.get<dynamic>('me'),
        client.get<dynamic>('me'),
        client.get<dynamic>('me'),
      ]);
      expect(refreshCalls, 1);
      for (final r in results) {
        expect(r.isSuccess, true);
      }
      for (final request in mock.received) {
        expect(
          request.headers.keys
              .where((key) => key.toLowerCase().startsWith('x-fac-')),
          isEmpty,
        );
      }
    });
  });

  group('AuthInterceptor edge cases', () {
    test('skips auth header when token is empty string', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/open$'), statusCode: 200, body: {});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => '',
        ),
      );

      await client.get<dynamic>('open');
      expect(mock.received.first.headers.containsKey('Authorization'), false);
    });

    test('uses custom authScheme prefix', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/api$'), statusCode: 200, body: {});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'mytoken',
          authScheme: 'Token',
        ),
      );

      await client.get<dynamic>('api');
      expect(mock.received.first.headers['Authorization'], 'Token mytoken');
    });

    test('empty authScheme sends bare token without prefix', () async {
      final mock = MockAdapter()
        ..on('GET', RegExp(r'/raw$'), statusCode: 200, body: {});
      final client = ApiClient(
        ApiClientConfig(
          baseUrl: 'https://api.example.com',
          adapter: mock,
          getAccessToken: () async => 'rawtoken',
          authScheme: '',
        ),
      );

      await client.get<dynamic>('raw');
      expect(mock.received.first.headers['Authorization'], 'rawtoken');
    });
  });
}
