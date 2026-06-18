import 'dart:async';

import 'api_exception.dart';

/// Cancels one or more in-flight requests from the package API perspective.
///
/// A single token can be passed to many requests. Calling [cancel] causes
/// those requests to complete with [CancelError] without disturbing unrelated
/// ones.
///
/// Transport-level interruption depends on the active adapter. The default
/// [DefaultHttpAdapter] attempts to interrupt owned per-request `package:http`
/// clients, but shared injected clients are not closed by one request cancel.
class CancelToken {
  CancelToken();

  final _completer = Completer<CancelError>();
  final List<void Function(CancelError)> _listeners = [];
  CancelError? _error;
  bool _disposed = false;

  /// True after [cancel] has been called.
  bool get isCancelled => _error != null;

  /// True after [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Number of currently registered listeners. Exposed so callers can verify
  /// that listeners are released (e.g. after a request completes).
  int get listenerCount => _listeners.length;

  /// Resolves when this token is cancelled. Never completes if the token is
  /// [dispose]d before being cancelled.
  Future<CancelError> get whenCancelled => _completer.future;

  /// The cancellation error, if cancelled.
  CancelError? get error => _error;

  /// Cancels every request bound to this token.
  ///
  /// Idempotent and a no-op after [dispose]: a disposed token can no longer
  /// be cancelled, preserving the invariant that a disposed token fires no
  /// further listeners.
  void cancel([String reason = 'Request cancelled']) {
    if (_error != null || _disposed) return;
    final err = CancelError(reason);
    _error = err;
    for (final l in List.of(_listeners)) {
      try {
        l(err);
      } catch (_) {}
    }
    _listeners.clear();
    if (!_completer.isCompleted) _completer.complete(err);
  }

  /// Registers a callback fired when the token is cancelled.
  /// Returns a function to unregister the listener.
  ///
  /// If the token is already cancelled the listener fires immediately. If the
  /// token is already disposed the listener is never registered or fired.
  void Function() addListener(void Function(CancelError) listener) {
    if (_disposed) return () {};
    if (_error != null) {
      listener(_error!);
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Throws a [CancelError] if cancelled.
  void throwIfCancelled() {
    if (_error != null) throw _error!;
  }

  /// Releases all listeners without cancelling.
  ///
  /// Use when a token's owning scope is torn down but its requests already
  /// finished — this clears the listener list (preventing leaks) and resolves
  /// any pending [whenCancelled] awaiters as a no-op completion only if the
  /// token was never cancelled. Safe to call multiple times. After dispose the
  /// token cannot be cancelled and registers no new listeners.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    // Leave a cancelled token's completer as-is (already completed with the
    // CancelError). For an un-cancelled token we deliberately do NOT complete
    // the future, so `whenCancelled` only ever resolves on a real cancel.
  }
}
