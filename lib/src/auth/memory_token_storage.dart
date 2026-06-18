import 'token_storage.dart';

/// In-memory [TokenStorage] for tests or simple use cases.
///
/// Tokens live only for the lifetime of this instance; nothing is persisted
/// across restarts.
class MemoryTokenStorage implements TokenStorage {
  /// Creates a store optionally seeded with an [accessToken] and
  /// [refreshToken].
  MemoryTokenStorage({String? accessToken, String? refreshToken})
      : _accessToken = accessToken,
        _refreshToken = refreshToken;

  String? _accessToken;
  String? _refreshToken;

  @override
  Future<String?> getAccessToken() => Future.value(_accessToken);

  @override
  Future<void> setAccessToken(String? token) async {
    _accessToken = token;
  }

  @override
  Future<String?> getRefreshToken() => Future.value(_refreshToken);

  @override
  Future<void> setRefreshToken(String? token) async {
    _refreshToken = token;
  }

  @override
  Future<void> clear() async {
    _accessToken = null;
    _refreshToken = null;
  }
}
