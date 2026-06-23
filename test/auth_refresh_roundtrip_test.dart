// Full round-trip proof of the concurrent-401 refresh contract through the
// REAL ApiClient (not the interceptor in isolation):
//
//   When several requests are in flight and all get 401, EXACTLY ONE refresh
//   fires, the refresh's (slow) token write completes before any retry reads
//   the token, and every retry then carries the NEW token to the wire.
//
// Each test has a timeout guard so a re-introduced deadlock fails loudly.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// TokenStorage whose WRITE is slow (persistence takes time) but whose READ is
/// fast. `getAccessToken` only returns the new value once the write landed —
/// so a retry that reads before the write completes would observe the stale
/// token. This is exactly the "it takes time to write to storage" worry.
class _SlowWriteStorage implements TokenStorage {
  _SlowWriteStorage(this._access,
      {this.writeDelay = const Duration(milliseconds: 30)});
  String? _access;
  final Duration writeDelay;
  int writes = 0;

  @override
  Future<String?> getAccessToken() async => _access;

  @override
  Future<void> setAccessToken(String? token) async {
    await Future<void>.delayed(writeDelay); // slow persistence
    _access = token;
    writes++;
  }

  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<void> setRefreshToken(String? token) async {}
  @override
  Future<void> clear() async => _access = null;
}

Future<R> _within<R>(Future<R> f,
        {Duration d = const Duration(seconds: 5)}) =>
    f.timeout(d, onTimeout: () => throw StateError('deadlock / liveness fault'));

void main() {
  group('Concurrent 401 -> single refresh -> retries use the new token', () {
    test(
        'six concurrent 401s coalesce to ONE refresh; every retry waits for '
        'the slow write and succeeds with the NEW token', () async {
      var refreshes = 0;
      var hits = 0;
      final storage = _SlowWriteStorage('OLD');

      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        hits++;
        // Server accepts ONLY the refreshed token. If a retry ever sent the
        // stale token (write not yet landed), it would 401 again and fail.
        if (req.headers['Authorization'] == 'Bearer NEW') {
          return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('"ok"'),
          );
        }
        return AdapterResponse(
            statusCode: 401, headers: const {}, bodyBytes: Uint8List(0));
      });

      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        tokenStorage: storage,
        refreshToken: () async {
          refreshes++;
          // The refresh MUST await the slow persistence before returning so the
          // retry reads the fresh token.
          await storage.setAccessToken('NEW');
          return true;
        },
        adapter: mock,
        // No dedup: each GET runs its own chain, so all six genuinely reach the
        // 401 handler concurrently.
      ));

      final results = await _within(Future.wait([
        for (var i = 0; i < 6; i++) client.get<dynamic>('me'),
      ]));

      for (final r in results) {
        expect(r.isSuccess, isTrue);
        expect(r.statusCode, 200);
      }
      // Single-flight + staleness-guard backstop: no matter how the six
      // interleave, only one refresh fires for the whole cohort.
      expect(refreshes, 1, reason: 'concurrent 401s => exactly one refresh');
      // 6 initial 401s + 6 retried 200s.
      expect(hits, 12, reason: 'one initial + one retry per request');
      expect(storage.writes, 1, reason: 'token written exactly once');
    });

    test(
        'CachedTokenStorage: the new token is usable immediately while the '
        'slow disk write is still pending, and it still persists', () async {
      final delegate =
          _SlowWriteStorage('OLD', writeDelay: const Duration(milliseconds: 60));
      final cached = CachedTokenStorage(delegate);
      var refreshes = 0;

      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (req) async {
        if (req.headers['Authorization'] == 'Bearer NEW') {
          return AdapterResponse(
            statusCode: 200,
            headers: const {'content-type': 'application/json'},
            bodyBytes: _b('"ok"'),
          );
        }
        return AdapterResponse(
            statusCode: 401, headers: const {}, bodyBytes: Uint8List(0));
      });

      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        tokenStorage: cached,
        refreshToken: () async {
          refreshes++;
          // CachedTokenStorage updates its in-memory cache synchronously and
          // persists to the slow delegate in the background, so this returns
          // fast and the cache already holds NEW.
          await cached.setAccessToken('NEW');
          return true;
        },
        adapter: mock,
      ));

      final results = await _within(Future.wait([
        for (var i = 0; i < 4; i++) client.get<dynamic>('me'),
      ]));

      // Retries succeeded reading NEW from the cache, well before the 60ms
      // delegate write could have completed.
      for (final r in results) {
        expect(r.statusCode, 200);
      }
      expect(refreshes, 1);

      // The slow persistence still lands.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(delegate.writes, 1, reason: 'token persisted to the slow backend');
      expect(await delegate.getAccessToken(), 'NEW');
    });

    test('a refresh that forgets to persist does NOT loop forever', () async {
      // Edge case: the user-supplied refresh returns true but never writes the
      // token. The retried-once guard must terminate instead of refreshing and
      // retrying endlessly.
      var refreshes = 0;
      var hits = 0;
      final storage = MemoryTokenStorage(accessToken: 'OLD');

      final mock = MockAdapter();
      mock.onRequest('GET', RegExp(r'/me$'), (_) async {
        hits++;
        return AdapterResponse(
            statusCode: 401, headers: const {}, bodyBytes: Uint8List(0));
      });

      final client = ApiClient(ApiClientConfig(
        baseUrl: 'https://api.example.com',
        tokenStorage: storage,
        refreshToken: () async {
          refreshes++;
          return true; // BUG in caller: forgot to write the new token.
        },
        adapter: mock,
      ));

      final r = await _within(client.get<dynamic>('me'));
      expect(r.statusCode, 401, reason: 'surfaces the 401, does not hang');
      expect(refreshes, 1, reason: 'one refresh attempt');
      expect(hits, 2, reason: 'initial + one retry, then the guard stops it');
    });
  });
}
