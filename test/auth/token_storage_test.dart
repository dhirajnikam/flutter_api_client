import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Test double that counts delegate reads.
class _CountingStorage implements TokenStorage {
  _CountingStorage({required String Function() onRead}) : _onRead = onRead;

  final String Function() _onRead;

  @override
  Future<String?> getAccessToken() async => _onRead();

  @override
  Future<void> setAccessToken(String? token) async {}

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<void> setRefreshToken(String? token) async {}

  @override
  Future<void> clear() async {}
}

void main() {
  group('CachedTokenStorage — background write safety', () {
    test('clear flushes pending writes so a token cannot be resurrected',
        () async {
      final delegate = _SlowTokenStorage();
      final cached = CachedTokenStorage(delegate);

      await cached.setAccessToken('fresh-token');
      // The delegate write is still in flight here; if it overtook clear()
      // the token would land on disk after logout.
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

  group('Token storage', () {
    test('memory get/set', () async {
      final s = MemoryTokenStorage(accessToken: 't');
      expect(await s.getAccessToken(), 't');
      await s.setAccessToken('x');
      expect(await s.getAccessToken(), 'x');
    });

    test('cached returns memory first', () async {
      final s = CachedTokenStorage(MemoryTokenStorage(accessToken: 'c'));
      expect(await s.getAccessToken(), 'c');
      s.updateAccessToken('new');
      expect(await s.getAccessToken(), 'new');
    });

    test('cached persists in background', () async {
      final inner = MemoryTokenStorage();
      final s = CachedTokenStorage(inner);
      s.updateAccessToken('immediate');
      expect(await s.getAccessToken(), 'immediate');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await inner.getAccessToken(), 'immediate');
    });
  });

  group('CachedTokenStorage.clearCache', () {
    test('after clearCache next read hits delegate again', () async {
      var delegateReads = 0;
      final inner = _CountingStorage(onRead: () {
        delegateReads++;
        return 'token-from-delegate';
      });
      final cached = CachedTokenStorage(inner);

      await cached.getAccessToken();
      expect(delegateReads, 1);

      await cached.getAccessToken();
      expect(delegateReads, 1);

      cached.clearCache();

      await cached.getAccessToken();
      expect(delegateReads, 2);
    });

    test('clear() awaits delegate.clear() and drops cache', () async {
      final inner = MemoryTokenStorage(accessToken: 'abc');
      final cached = CachedTokenStorage(inner);

      await cached.getAccessToken();

      await cached.clear();

      expect(await cached.getAccessToken(), isNull);
      expect(await inner.getAccessToken(), isNull);
    });
  });
}
