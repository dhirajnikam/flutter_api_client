import 'dart:async';

import 'offline_queue.dart';
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
/// - [syncNow] runs a pass on demand (e.g. app foregrounded, or from an OS
///   background task you schedule yourself).
/// - After the uploads, [fetchSteps] run in order — but only once the queue is
///   empty, so a pull never overwrites local changes that are still waiting to
///   be sent. A step that returns `false` or throws stops the sequence; the
///   whole pass is retried after [retryDelay] while [onlineStream] says the
///   device is online.
///
/// All failure handling is per-request inside the replayer; this class never
/// throws from stream events.
class OfflineSyncManager {
  OfflineSyncManager({
    required this.replayer,
    this.onlineStream,
    this.retryDelay = const Duration(seconds: 30),
    this.replayOnStart = false,
    this.onReport,
    this.fetchSteps = const [],
  });

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

  /// Fetches to run, in list order, after every pass that leaves the queue
  /// empty (including a pass that had nothing to upload). Each step returns
  /// whether it succeeded, e.g.
  /// `() async => (await client.get('todos')).isSuccess`. The first step that
  /// returns `false` or throws stops the sequence, and the pass is retried
  /// after [retryDelay] (as for uploads: only while [onlineStream] reports
  /// online); a retry starts again from the first step.
  final List<Future<bool> Function()> fetchSteps;

  StreamSubscription<bool>? _subscription;
  Future<(OfflineReplayReport, bool)>? _inFlight;
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
  Future<OfflineReplayReport?> syncNow() async => (await _runPass())?.$1;

  /// Runs one full pass — the uploads, then [fetchSteps] — and returns whether
  /// everything finished: nothing was put back in the queue and every fetch
  /// step succeeded. Needs neither [start] nor [onlineStream] and schedules no
  /// retry of its own without them, which makes it the call for an OS
  /// background task (`workmanager`, `background_fetch`) running while the app
  /// is in the background or terminated: return its result so the OS retries
  /// only when work is left. Returns `false` after [dispose].
  Future<bool> runOnce() async => (await _runPass())?.$2 ?? false;

  // One pass at a time: overlapping triggers share it, so the report and the
  // fetch steps run once rather than once per trigger. The bool is whether
  // the pass finished everything.
  Future<(OfflineReplayReport, bool)?> _runPass() {
    if (_disposed) return Future.value();
    return _inFlight ??= _pass().whenComplete(() => _inFlight = null);
  }

  Future<(OfflineReplayReport, bool)> _pass() async {
    final report = await replayer.replay();
    if (_disposed) return (report, false);
    _notify(report);
    final fetched = await _fetch();
    if (_disposed) return (report, false);
    // Uploads went back into the queue, or the fetch sequence did not finish:
    // try again later, as long as we still believe we're online.
    if ((report.reEnqueued > 0 || !fetched) && _online) {
      _retryTimer?.cancel();
      _retryTimer = Timer(retryDelay, () {
        _retryTimer = null;
        if (!_disposed && _online) _runPass();
      });
    }
    return (report, fetched && report.reEnqueued == 0);
  }

  /// Runs [fetchSteps] in order. Returns `false` when the sequence did not
  /// complete: writes are still queued, or a step failed.
  Future<bool> _fetch() async {
    if (fetchSteps.isEmpty) return true;
    try {
      // Count what a pass can actually send: a store's raw length may include
      // an unreadable record that would otherwise block fetching forever.
      final store = replayer.store;
      final pending = store is PeekableOfflineQueueStore
          ? (await store.peekAll()).length
          : await store.length;
      if (pending > 0) return false;
      for (final step in fetchSteps) {
        if (_disposed) return false;
        if (!await step()) return false;
      }
      return true;
    } catch (_) {
      // A step bug must not surface as an unhandled error; retry later.
      return false;
    }
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
