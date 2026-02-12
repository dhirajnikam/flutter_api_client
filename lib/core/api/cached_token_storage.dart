import 'dart:async';

import 'token_storage.dart';

/// Wraps any [TokenStorage] with in-memory cache.
///
/// - **getAccessToken()**: Returns from memory first (fast). On cache miss,
///   loads from storage and caches.
/// - **setAccessToken()**: Updates memory immediately and returns. Persists
///   to storage in the background (non-blocking).
///
/// Use this when storage (SharedPreferences, SecureStorage, etc.) is slow:
/// ```dart
/// final storage = CachedTokenStorage(SharedPrefsTokenStorage(prefs));
/// ```
class CachedTokenStorage implements TokenStorage {
  CachedTokenStorage(this._delegate);

  final TokenStorage _delegate;

  String? _cachedAccessToken;
  String? _cachedRefreshToken;
  bool _accessTokenLoaded = false;
  bool _refreshTokenLoaded = false;

  @override
  Future<String?> getAccessToken() async {
    if (_accessTokenLoaded) {
      return _cachedAccessToken;
    }
    _cachedAccessToken = await _delegate.getAccessToken();
    _accessTokenLoaded = true;
    return _cachedAccessToken;
  }

  @override
  Future<void> setAccessToken(String? token) async {
    _cachedAccessToken = token;
    _accessTokenLoaded = true;
    unawaited(_delegate.setAccessToken(token));
  }

  @override
  Future<String?> getRefreshToken() async {
    if (_refreshTokenLoaded) {
      return _cachedRefreshToken;
    }
    _cachedRefreshToken = await _delegate.getRefreshToken();
    _refreshTokenLoaded = true;
    return _cachedRefreshToken;
  }

  @override
  Future<void> setRefreshToken(String? token) async {
    _cachedRefreshToken = token;
    _refreshTokenLoaded = true;
    unawaited(_delegate.setRefreshToken(token));
  }

  /// Clears the in-memory cache. Next [getAccessToken] will load from storage.
  void clearCache() {
    _cachedAccessToken = null;
    _cachedRefreshToken = null;
    _accessTokenLoaded = false;
    _refreshTokenLoaded = false;
  }

  /// Updates cache immediately, persists to storage in background. Use after
  /// refresh API: use token right away, storage happens async.
  void updateAccessToken(String? token) {
    _cachedAccessToken = token;
    _accessTokenLoaded = true;
    unawaited(_delegate.setAccessToken(token));
  }

  /// Updates refresh token cache, persists in background.
  void updateRefreshToken(String? token) {
    _cachedRefreshToken = token;
    _refreshTokenLoaded = true;
    unawaited(_delegate.setRefreshToken(token));
  }
}
