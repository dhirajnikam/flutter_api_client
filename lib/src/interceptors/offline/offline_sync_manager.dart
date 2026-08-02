import 'dart:async';

import 'offline_queue_replayer.dart';

/// Drives [OfflineQueueReplayer] automatically from a connectivity signal.
///
/// The offline pipeline has three parts: `OfflineQueueInterceptor` captures
/// failed writes, [OfflineQueueReplayer] delivers them, and this manager
/// decides *when* to deliver. Feed it any `Stream<bool>` that emits `true`
/// when the device comes online (e.g. mapped from a `connectivity_plus`
/// stream — this package stays dependency-light and does not bundle one):
///
/// ```dart
/// final sync = OfflineSyncManager(
///   replayer: replayer,
///   onlineStream: Connectivity()
///       .onConnectivityChanged
///       .map((r) => !r.contains(ConnectivityResult.none)),
///   onReport: (report) => log('offline sync: $report'),
/// );
/// sync.start();
/// // ...on logout / teardown:
/// await sync.dispose();
/// ```
///
/// Behavior:
/// - Every `true` event triggers a replay pass (concurrent triggers coalesce
///   into one pass via the replayer).
/// - If a pass re-enqueues transient failures, another pass is scheduled
///   after [retryDelay] — so a flaky reconnect still drains the queue —
///   until a pass ends with nothing re-enqueued, the device goes offline,
///   or the manager is disposed.
/// - A `false` event cancels any scheduled retry pass.
/// - [syncNow] runs a pass on demand (e.g. app foregrounded).
///
/// All failure handling is per-request inside the replayer; this class never
/// throws from stream events.
class OfflineSyncManager {
  /// Creates a manager that drives [replayer] from [onlineStream].
  OfflineSyncManager({
    required this.replayer,
    this.onlineStream,
    this.retryDelay = const Duration(seconds: 30),
    this.replayOnStart = false,
    this.onReport,
  });

  /// Replayer that delivers the queued writes.
  final OfflineQueueReplayer replayer;

  /// Emits `true` when connectivity returns, `false` when it drops. Optional:
  /// without it, only [syncNow] and [replayOnStart] trigger passes.
  final Stream<bool>? onlineStream;

  /// Delay before re-running a pass that left transient failures re-enqueued.
  final Duration retryDelay;

  /// Whether [start] immediately runs a first pass (useful at app launch to
  /// drain writes queued in a previous session).
  final bool replayOnStart;

  /// Called with the report of every completed pass.
  final void Function(OfflineReplayReport report)? onReport;

  StreamSubscription<bool>? _subscription;
  Timer? _retryTimer;
  bool _online = false;
  bool _disposed = false;
  bool _started = false;

  /// Whether [start] has been called and [dispose] has not.
  bool get isRunning => _started && !_disposed;

  /// Begins listening to [onlineStream]. Safe to call once; subsequent calls
  /// are no-ops. Returns synchronously; passes run in the background.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    final stream = onlineStream;
    if (stream != null) {
      _subscription = stream.listen((online) {
        if (_disposed) return;
        _online = online;
        if (online) {
          _runPass();
        } else {
          _retryTimer?.cancel();
          _retryTimer = null;
        }
      });
    }
    if (replayOnStart) {
      _online = true;
      _runPass();
    }
  }

  /// Runs one replay pass immediately and returns its report. Coalesces with
  /// any pass already in flight. Returns `null` after [dispose].
  Future<OfflineReplayReport?> syncNow() async {
    if (_disposed) return null;
    return _runPass();
  }

  Future<OfflineReplayReport?> _runPass() async {
    if (_disposed) return null;
    final report = await replayer.replay();
    if (_disposed) return report;
    _notify(report);
    // Transient failures went back into the queue: try again later, as long
    // as we still believe we're online. A new connectivity event or an
    // explicit syncNow() replaces this schedule naturally (passes coalesce).
    if (report.reEnqueued > 0 && _online) {
      _retryTimer?.cancel();
      _retryTimer = Timer(retryDelay, () {
        _retryTimer = null;
        if (!_disposed && _online) _runPass();
      });
    }
    return report;
  }

  void _notify(OfflineReplayReport report) {
    final cb = onReport;
    if (cb == null) return;
    try {
      cb(report);
    } catch (_) {
      // A listener bug must not break the sync loop.
    }
  }

  /// Stops listening and cancels any scheduled pass. Idempotent. A pass that
  /// is already in flight finishes but schedules nothing further.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }
}
