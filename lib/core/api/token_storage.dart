/// Interface for custom token storage.
///
/// Implement this to use SharedPreferences, SecureStorage, GetIt, Hive,
/// or any other storage mechanism.
///
/// Example with SharedPreferences:
/// ```dart
/// class SharedPrefsTokenStorage implements TokenStorage {
///   SharedPrefsTokenStorage(this._prefs);
///   final SharedPreferences _prefs;
///
///   @override
///   Future<String?> getAccessToken() => Future.value(_prefs.getString('access_token'));
///
///   @override
///   Future<void> setAccessToken(String? token) async {
///     if (token != null) {
///       await _prefs.setString('access_token', token);
///     } else {
///       await _prefs.remove('access_token');
///     }
///   }
/// }
/// ```
abstract class TokenStorage {
  /// Returns the stored access token, or null if not set.
  Future<String?> getAccessToken();

  /// Saves the access token. Pass null to clear.
  Future<void> setAccessToken(String? token);

  /// Optional: Returns the refresh token. Override if using token refresh.
  Future<String?> getRefreshToken() => Future.value(null);

  /// Optional: Saves the refresh token. Override if using token refresh.
  Future<void> setRefreshToken(String? token) => Future.value();
}
