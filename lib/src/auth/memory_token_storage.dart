import 'token_storage.dart';

/// In-memory token storage for tests or simple use cases.
class MemoryTokenStorage implements TokenStorage {
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
