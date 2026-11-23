import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Connection lifecycle of a [WebSocketClient].
enum WebSocketState {
  /// Created, [WebSocketClient.connect] not called yet.
  idle,

  /// A connection attempt is in flight.
  connecting,

  /// Connected; messages flow.
  open,

  /// The connection dropped and a reconnect is waiting out its backoff delay.
  reconnecting,

  /// Closed for good: by [WebSocketClient.close], or because reconnecting is
  /// disabled or exhausted.
  closed,
}

/// The transport a [WebSocketClient] drives.
///
/// The default implementation wraps `package:web_socket_channel`. Implement it
/// to plug in another transport, or to fake one in tests.
abstract class WebSocketConnection {
  /// Incoming frames: `String` for text, `List<int>` for binary. Closes when
  /// the connection ends.
  Stream<dynamic> get stream;

  /// Completes when the connection is open; fails if it cannot be opened.
  Future<void> get ready;

  /// The close code, once the connection has ended.
  int? get closeCode;

  /// The close reason, once the connection has ended.
  String? get closeReason;

  /// Sends a frame: a `String` (text) or `List<int>` (binary).
  void add(Object frame);

  /// Closes the connection.
  Future<void> close([int? code, String? reason]);
}

/// Opens a [WebSocketConnection] to [url].
typedef WebSocketConnector = WebSocketConnection Function(
  Uri url,
  Iterable<String>? protocols,
);

/// Why and how a connection ended.
class WebSocketCloseInfo {
  /// Creates a close record.
  const WebSocketCloseInfo({
    required this.code,
    required this.reason,
    required this.willReconnect,
  });

  /// WebSocket close code (`1006` when the connection was lost abnormally).
  final int code;

  /// Close reason, empty if none was given.
  final String reason;

  /// Whether a reconnect is scheduled.
  final bool willReconnect;
}

/// Auto-reconnect policy: exponential backoff with optional jitter.
class WebSocketReconnect {
  /// Creates a policy.
  const WebSocketReconnect({
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    this.maxAttempts,
    this.jitter = true,
    this.shouldReconnect,
  });

  /// Delay before the first reconnect; doubled for each further attempt.
  final Duration baseDelay;

  /// Upper bound for the delay.
  final Duration maxDelay;

  /// Give up after this many consecutive failed attempts. `null` never gives
  /// up. A successful open resets the count.
  final int? maxAttempts;

  /// Randomizes each delay to 50–100% of its value so that clients do not
  /// reconnect in lockstep after a server restart.
  final bool jitter;

  /// Return `false` to stop reconnecting after this close, for example on an
  /// authentication close code.
  final bool Function(int code, String reason)? shouldReconnect;
}

/// Keep-alive: sends a ping after a period without traffic and drops the
/// connection (so it reconnects) when the server stays silent.
class WebSocketHeartbeat {
  /// Creates a heartbeat.
  const WebSocketHeartbeat({
    required this.interval,
    this.message = 'ping',
    this.messageBuilder,
    this.timeout,
  });

  /// Send a ping after this long without sending or receiving anything.
  final Duration interval;

  /// Payload of the ping, encoded like any other outgoing message.
  final Object? message;

  /// Builds the ping payload each time; takes precedence over [message].
  final Object? Function()? messageBuilder;

  /// Drop the connection if nothing arrives within this long of a ping. Any
  /// incoming frame counts as the reply. Defaults to [interval].
  final Duration? timeout;
}

/// WebSocket client with auto-reconnect, heartbeat, a queue for messages sent
/// while disconnected, and JSON framing by default.
///
/// ```dart
/// final ws = WebSocketClient<Object?>(url: 'wss://api.example.com/live');
/// ws.messages.listen(print);
/// ws.connect();
/// ws.send({'type': 'subscribe', 'channel': 'orders'});
/// ```
///
/// Outgoing values that are not a `String` or `List<int>` are JSON-encoded.
/// Incoming text frames are JSON-decoded, falling back to the raw string when
/// they are not JSON; binary frames arrive as [Uint8List]. Supply [encode] /
/// [decode] to change either side.
class WebSocketClient<T> {
  /// Creates a client. Exactly one of [url] and [urlProvider] is required.
  ///
  /// [urlProvider] is called before every connection attempt, which makes it
  /// the place to append a fresh auth token. Pass `reconnect: null` to disable
  /// auto-reconnect.
  WebSocketClient({
    String? url,
    FutureOr<String> Function()? urlProvider,
    this.protocols,
    this.reconnect = const WebSocketReconnect(),
    this.heartbeat,
    this.connectTimeout = const Duration(seconds: 15),
    this.maxQueue = 100,
    Object Function(Object? data)? encode,
    T Function(Object frame)? decode,
    WebSocketConnector? connector,
    Random? random,
  })  : assert(
          (url == null) != (urlProvider == null),
          'Pass exactly one of url and urlProvider',
        ),
        _url = url,
        _urlProvider = urlProvider,
        _encode = encode ?? _defaultEncode,
        _decode = decode,
        _connector = connector ?? _channelConnector,
        _random = random ?? Random();

  /// Sub-protocols offered to the server.
  final Iterable<String>? protocols;

  /// Reconnect policy; `null` disables auto-reconnect.
  final WebSocketReconnect? reconnect;

  /// Heartbeat settings; `null` sends no pings.
  final WebSocketHeartbeat? heartbeat;

  /// A connection attempt that has not opened within this long fails.
  final Duration connectTimeout;

  /// Messages sent while disconnected are kept, up to this many (the oldest
  /// are dropped), and flushed in order on open. `0` disables queueing.
  final int maxQueue;

  final String? _url;
  final FutureOr<String> Function()? _urlProvider;
  final Object Function(Object? data) _encode;
  final T Function(Object frame)? _decode;
  final WebSocketConnector _connector;
  final Random _random;

  final _messages = StreamController<T>.broadcast();
  final _states = StreamController<WebSocketState>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _closes = StreamController<WebSocketCloseInfo>.broadcast();

  WebSocketConnection? _connection;
  // Cancelled in _teardown, which the lint cannot follow.
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _subscription;
  WebSocketState _state = WebSocketState.idle;
  final List<Object> _queue = [];
  int _attempts = 0;

  /// Bumped on every connect and close, so callbacks from a superseded
  /// connection are ignored.
  int _generation = 0;
  Timer? _reconnectTimer;
  Timer? _connectTimer;
  Timer? _heartbeatTimer;
  Timer? _pongTimer;
  bool _disposed = false;

  /// Decoded incoming messages.
  Stream<T> get messages => _messages.stream;

  /// Every change of [state].
  Stream<WebSocketState> get states => _states.stream;

  /// Transport errors, connect and heartbeat timeouts, and decode failures.
  Stream<Object> get errors => _errors.stream;

  /// One event each time a connection ends.
  Stream<WebSocketCloseInfo> get closes => _closes.stream;

  /// Current lifecycle state.
  WebSocketState get state => _state;

  /// Whether the connection is open.
  bool get isOpen => _state == WebSocketState.open;

  /// Number of messages waiting for the connection to open.
  int get queued => _queue.length;

  /// Opens the connection. A no-op while connecting, open, or waiting to
  /// reconnect, and after [dispose].
  void connect() {
    if (_disposed ||
        _state == WebSocketState.connecting ||
        _state == WebSocketState.open ||
        _state == WebSocketState.reconnecting) {
      return;
    }
    _attempts = 0;
    unawaited(_open());
  }

  /// Sends [data]. Returns `true` when it was written to the socket now, and
  /// `false` when it was queued for the next open (or dropped because
  /// [maxQueue] is `0`).
  bool send(Object? data) {
    final frame = _encode(data);
    final connection = _connection;
    if (connection != null && _state == WebSocketState.open) {
      connection.add(frame);
      _armHeartbeat();
      return true;
    }
    if (maxQueue > 0 && !_disposed) {
      _queue.add(frame);
      if (_queue.length > maxQueue) {
        _queue.removeRange(0, _queue.length - maxQueue);
      }
    }
    return false;
  }

  /// Closes for good: no reconnect, queued messages are dropped. Call
  /// [connect] to start over.
  Future<void> close([int code = 1000, String reason = '']) async {
    final wasActive =
        _state != WebSocketState.idle && _state != WebSocketState.closed;
    _generation++;
    _clearTimers();
    _queue.clear();
    _teardown(code, reason);
    _setState(WebSocketState.closed);
    if (wasActive) {
      _emit(
        _closes,
        WebSocketCloseInfo(code: code, reason: reason, willReconnect: false),
      );
    }
  }

  /// Closes the connection and the event streams. The client cannot be used
  /// afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    await close();
    _disposed = true;
    await Future.wait([
      _messages.close(),
      _states.close(),
      _errors.close(),
      _closes.close(),
    ]);
  }

  Future<void> _open() async {
    final gen = ++_generation;
    _setState(WebSocketState.connecting);
    final WebSocketConnection connection;
    try {
      final url = _url ?? await _urlProvider!();
      // Closed (or superseded) while the URL was being resolved.
      if (gen != _generation) return;
      connection = _connector(Uri.parse(url), protocols);
    } catch (e) {
      if (gen != _generation) return;
      _emit(_errors, e);
      _dropped(gen, 1006, 'connect failed');
      return;
    }
    _connection = connection;

    _connectTimer = Timer(connectTimeout, () {
      _emit(
        _errors,
        TimeoutException('WebSocket connect timed out', connectTimeout),
      );
      _dropped(gen, 1006, 'connect timeout');
    });

    _subscription = connection.stream.listen(
      (dynamic frame) => _onFrame(gen, frame),
      onError: (Object e) {
        if (gen == _generation) _emit(_errors, e);
      },
      onDone: () => _dropped(
        gen,
        connection.closeCode ?? 1006,
        connection.closeReason ?? '',
      ),
    );

    try {
      await connection.ready;
    } catch (e) {
      if (gen != _generation) return;
      _emit(_errors, e);
      _dropped(gen, 1006, 'connect failed');
      return;
    }
    if (gen != _generation) return;
    _connectTimer?.cancel();
    _attempts = 0;
    _setState(WebSocketState.open);
    final pending = List<Object>.of(_queue);
    _queue.clear();
    pending.forEach(connection.add);
    _armHeartbeat();
  }

  void _onFrame(int gen, dynamic frame) {
    if (gen != _generation) return;
    _pongTimer?.cancel();
    _pongTimer = null;
    _armHeartbeat();
    final T decoded;
    try {
      final Object raw = frame is String
          ? frame
          : frame is Uint8List
              ? frame
              : Uint8List.fromList(frame as List<int>);
      final decode = _decode;
      decoded = decode != null ? decode(raw) : _defaultDecode(raw) as T;
    } catch (e) {
      _emit(_errors, e);
      return;
    }
    _emit(_messages, decoded);
  }

  /// The current connection is gone (closed by the peer, failed, or timed
  /// out): schedule a reconnect or settle as closed.
  void _dropped(int gen, int code, String reason) {
    if (gen != _generation) return;
    _generation++;
    _clearTimers();
    _teardown(null, null);

    final policy = reconnect;
    final attempt = _attempts++;
    final maxAttempts = policy?.maxAttempts;
    final willReconnect = policy != null &&
        (maxAttempts == null || attempt < maxAttempts) &&
        (policy.shouldReconnect?.call(code, reason) ?? true);

    _setState(
      willReconnect ? WebSocketState.reconnecting : WebSocketState.closed,
    );
    _emit(
      _closes,
      WebSocketCloseInfo(
        code: code,
        reason: reason,
        willReconnect: willReconnect,
      ),
    );
    if (!willReconnect) return;

    var delayMs = min(
      policy.baseDelay.inMilliseconds * pow(2, min(attempt, 30)),
      policy.maxDelay.inMilliseconds,
    ).toDouble();
    if (policy.jitter) delayMs *= 0.5 + _random.nextDouble() * 0.5;
    _reconnectTimer = Timer(
      Duration(milliseconds: delayMs.round()),
      () => unawaited(_open()),
    );
  }

  void _armHeartbeat() {
    final hb = heartbeat;
    if (hb == null) return;
    _heartbeatTimer?.cancel();
    final gen = _generation;
    _heartbeatTimer = Timer(hb.interval, () {
      final connection = _connection;
      if (gen != _generation ||
          connection == null ||
          _state != WebSocketState.open) {
        return;
      }
      final builder = hb.messageBuilder;
      connection.add(_encode(builder != null ? builder() : hb.message));
      _armHeartbeat();
      _pongTimer ??= Timer(hb.timeout ?? hb.interval, () {
        _emit(_errors, TimeoutException('WebSocket heartbeat timed out'));
        _dropped(gen, 1006, 'heartbeat timeout');
      });
    });
  }

  /// Detaches from the current connection and closes it. Never throws and
  /// never waits on the transport: closing a socket that is still connecting
  /// (or whose peer never answers the close) may not complete for a long time.
  void _teardown(int? code, String? reason) {
    final subscription = _subscription;
    final connection = _connection;
    _subscription = null;
    _connection = null;
    void ignore(Object _) {}
    try {
      unawaited(subscription?.cancel().catchError(ignore));
    } catch (_) {}
    try {
      unawaited(connection?.close(code, reason).catchError(ignore));
    } catch (_) {}
  }

  void _clearTimers() {
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _pongTimer?.cancel();
    _pongTimer = null;
  }

  void _setState(WebSocketState next) {
    if (next == _state) return;
    _state = next;
    _emit(_states, next);
  }

  void _emit<E>(StreamController<E> controller, E event) {
    if (!controller.isClosed) controller.add(event);
  }
}

Object _defaultEncode(Object? data) {
  if (data is String) return data;
  if (data is List<int>) return data;
  return jsonEncode(data);
}

Object? _defaultDecode(Object frame) {
  if (frame is! String) return frame;
  try {
    return jsonDecode(frame);
  } on FormatException {
    return frame;
  }
}

WebSocketConnection _channelConnector(Uri url, Iterable<String>? protocols) =>
    _ChannelConnection(WebSocketChannel.connect(url, protocols: protocols));

class _ChannelConnection implements WebSocketConnection {
  _ChannelConnection(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  Future<void> get ready => _channel.ready;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  void add(Object frame) => _channel.sink.add(frame);

  @override
  Future<void> close([int? code, String? reason]) async {
    await _channel.sink.close(code, reason);
  }
}
