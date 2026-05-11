/// Interface for token persistence.
///
/// Implement this to use SharedPreferences, SecureStorage, GetIt, Hive,
/// or any other backend.
abstract class TokenStorage {
  Future<String?> getAccessToken();
  Future<void> setAccessToken(String? token);
  Future<String?> getRefreshToken() => Future.value(null);
  Future<void> setRefreshToken(String? token) => Future.value();
  Future<void> clear() async {
    await setAccessToken(null);
    await setRefreshToken(null);
  }
}
