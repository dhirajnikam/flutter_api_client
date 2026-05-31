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

  /// True after [cancel] has been called.
  bool get isCancelled => _error != null;

  /// Resolves when this token is cancelled.
  Future<CancelError> get whenCancelled => _completer.future;

  /// The cancellation error, if cancelled.
  CancelError? get error => _error;

  /// Cancels every request bound to this token.
  void cancel([String reason = 'Request cancelled']) {
    if (_error != null) return;
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
  void Function() addListener(void Function(CancelError) listener) {
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
}
