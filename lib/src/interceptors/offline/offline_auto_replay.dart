import 'dart:async';

import 'offline_queue_replayer.dart';

/// Replays the offline queue automatically when connectivity returns.
///
/// The package bundles no connectivity library (to stay dependency-light), so
/// you feed it a `Stream<bool>` where `true` means "online". Wire it to whatever
/// you already use — `connectivity_plus`, `internet_connection_checker`, a
/// custom ping, or a test `StreamController`:
///
/// ```dart
/// final auto = OfflineAutoReplay(replayer: mutations.buildReplayer());
/// auto.bind(
///   Connectivity()
///       .onConnectivityChanged
///       .map((r) => r != ConnectivityResult.none),
/// );
/// // ... later, on logout / dispose:
/// await auto.dispose();
/// ```
///
/// Concurrency is handled for you: each `true` triggers a replay pass, and if a
/// pass is already running the trigger is coalesced into a single follow-up run
/// afterwards, so overlapping connectivity events never start overlapping
/// drains of the (destructive) queue. [trigger] is also public, so you can kick
/// a replay manually (e.g. from a "retry now" button).
class OfflineAutoReplay {
  /// Creates an auto-replayer driving [replayer]. [onReplayed] receives each
  /// pass's report; [onError] receives an error if a pass throws (by default the
  /// error is swallowed so a single failed pass does not tear down the stream
  /// subscription).
  OfflineAutoReplay({
    required this.replayer,
    this.onReplayed,
    this.onError,
  });

  /// The replayer each pass runs.
  final OfflineQueueReplayer replayer;

  /// Called with the report after each completed pass.
  final void Function(OfflineReplayReport report)? onReplayed;

  /// Called if a pass throws. When `null`, the error is swallowed.
  final void Function(Object error, StackTrace stackTrace)? onError;

  StreamSubscription<bool>? _sub;
  bool _running = false;
  bool _pending = false;

  /// Subscribes to [isOnline]; every `true` triggers a replay [trigger]. Call
  /// [dispose] to unsubscribe. Binding twice cancels the previous subscription.
  void bind(Stream<bool> isOnline) {
    _sub?.cancel();
    _sub = isOnline.listen((online) {
      if (online) unawaited(trigger());
    });
  }

  /// Runs a replay pass now, coalescing with any in-flight pass. Safe to call
  /// repeatedly; at most one pass runs at a time and one more is queued.
  Future<void> trigger() async {
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    try {
      do {
        _pending = false;
        try {
          final report = await replayer.replay();
          onReplayed?.call(report);
        } catch (e, st) {
          onError?.call(e, st);
        }
      } while (_pending);
    } finally {
      _running = false;
    }
  }

  /// Cancels the connectivity subscription. Call when done (e.g. on logout).
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
