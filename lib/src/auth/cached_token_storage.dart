import 'dart:async';

import 'token_storage.dart';

/// Wraps any [TokenStorage] with an in-memory cache so reads are sync-fast
/// and writes return immediately (persistence happens in the background).
class CachedTokenStorage implements TokenStorage {
  CachedTokenStorage(this._delegate);

  final TokenStorage _delegate;

  String? _accessToken;
  String? _refreshToken;
  bool _accessLoaded = false;
  bool _refreshLoaded = false;

  @override
  Future<String?> getAccessToken() async {
    if (_accessLoaded) return _accessToken;
    _accessToken = await _delegate.getAccessToken();
    _accessLoaded = true;
    return _accessToken;
  }

  @override
  Future<void> setAccessToken(String? token) async {
    _accessToken = token;
    _accessLoaded = true;
    unawaited(_delegate.setAccessToken(token));
  }

  @override
  Future<String?> getRefreshToken() async {
    if (_refreshLoaded) return _refreshToken;
    _refreshToken = await _delegate.getRefreshToken();
    _refreshLoaded = true;
    return _refreshToken;
  }

  @override
  Future<void> setRefreshToken(String? token) async {
    _refreshToken = token;
    _refreshLoaded = true;
    unawaited(_delegate.setRefreshToken(token));
  }

  /// Immediately updates cache, persists in background.
  void updateAccessToken(String? token) => setAccessToken(token);
  void updateRefreshToken(String? token) => setRefreshToken(token);

  /// Drops the in-memory cache. Next read will hit the delegate.
  void clearCache() {
    _accessToken = null;
    _refreshToken = null;
    _accessLoaded = false;
    _refreshLoaded = false;
  }

  @override
  Future<void> clear() async {
    clearCache();
    await _delegate.clear();
  }
}
