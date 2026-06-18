/// Interface for token persistence.
///
/// Implement this to back the auth layer with `SharedPreferences`,
/// `flutter_secure_storage`, Hive, GetIt, or any other store.
///
/// Contract for implementers:
/// - All methods are asynchronous; an implementation may complete
///   synchronously (e.g. an in-memory cache) but must still return a
///   [Future].
/// - `null` is the canonical "no token" value. Getters return `null` when no
///   token is stored; passing `null` to a setter clears that token.
/// - Refresh-token support is optional. The default [getRefreshToken] /
///   [setRefreshToken] implementations are no-ops, so a store that only holds
///   an access token needs to override nothing extra.
/// - Methods must not throw for the absence of a token; surface only genuine
///   backend failures.
abstract class TokenStorage {
  /// Returns the stored access token, or `null` if none is stored.
  Future<String?> getAccessToken();

  /// Stores [token] as the access token. Passing `null` clears it.
  Future<void> setAccessToken(String? token);

  /// Returns the stored refresh token, or `null` if none is stored.
  ///
  /// Defaults to `null`; override only if the backend persists refresh tokens.
  Future<String?> getRefreshToken() => Future<String?>.value();

  /// Stores [token] as the refresh token. Passing `null` clears it.
  ///
  /// Defaults to a no-op; override only if the backend persists refresh tokens.
  Future<void> setRefreshToken(String? token) => Future.value();

  /// Removes both the access and refresh tokens.
  ///
  /// The default implementation clears each token via its setter; override if
  /// the backend can drop both in a single, cheaper operation.
  Future<void> clear() async {
    await setAccessToken(null);
    await setRefreshToken(null);
  }
}
