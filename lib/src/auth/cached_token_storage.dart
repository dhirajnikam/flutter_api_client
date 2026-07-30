import 'token_storage.dart';

/// Wraps any [TokenStorage] with an in-memory cache so reads are sync-fast
/// and writes return immediately (persistence happens in the background).
///
/// The cache is populated on the first read of each token and kept in sync on
/// every write. Writes update the cache synchronously and forward to the
/// delegate without awaiting it, so a write returns before the slower backend
/// has finished persisting. Background writes are chained in order; a failed
/// delegate write is reported through [onWriteError] (and otherwise swallowed
/// so it never surfaces as an unhandled zone error).
class CachedTokenStorage implements TokenStorage {
  /// Wraps `delegate`, caching its tokens in memory. [onWriteError] receives
  /// errors from background delegate writes; when omitted they are dropped.
  CachedTokenStorage(this._delegate, {this.onWriteError});

  final TokenStorage _delegate;

  /// Called when a background delegate write fails. Optional; defaults to
  /// swallowing the error.
  final void Function(Object error, StackTrace st)? onWriteError;

  String? _accessToken;
  String? _refreshToken;
  bool _accessLoaded = false;
  bool _refreshLoaded = false;

  /// Pending background delegate writes, chained so they land in call order
  /// and [clear] can wait them out.
  Future<void> _pendingWrites = Future<void>.value();

  void _enqueueWrite(Future<void> Function() write) {
    _pendingWrites = _pendingWrites.then((_) => write()).then(
      (_) {},
      onError: (Object e, StackTrace st) {
        try {
          onWriteError?.call(e, st);
        } catch (_) {}
      },
    );
  }

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
    _enqueueWrite(() => _delegate.setAccessToken(token));
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
    _enqueueWrite(() => _delegate.setRefreshToken(token));
  }

  /// Fire-and-forget alias for [setAccessToken] when the caller does not need
  /// the [Future]: updates the cache immediately and persists in the
  /// background.
  void updateAccessToken(String? token) => setAccessToken(token);

  /// Fire-and-forget alias for [setRefreshToken]; see [updateAccessToken].
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
    // Flush the background write queue first: an in-flight setAccessToken
    // landing after the delegate clear would resurrect the token post-logout.
    // Writes enqueued while we wait are flushed too.
    Future<void> pending;
    do {
      pending = _pendingWrites;
      await pending;
    } while (!identical(pending, _pendingWrites));
    // Await the delegate before dropping the cache. If the delegate clear
    // fails, the cache still mirrors the (uncleared) backend instead of going
    // empty and resurrecting the persisted token on the next read.
    await _delegate.clear();
    clearCache();
  }
}
