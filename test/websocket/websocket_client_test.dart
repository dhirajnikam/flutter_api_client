import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fake clock of the running test. Every test runs in fake time: real
/// timers of a few milliseconds race the event loop and fail at random.
late FakeAsync _clock;

/// In-memory stand-in for a socket.
class FakeConnection implements WebSocketConnection {
  FakeConnection(this.url, this.protocols);

  final Uri url;
  final Iterable<String>? protocols;
  final _incoming = StreamController<dynamic>();
  final _ready = Completer<void>();
  final List<Object> sent = [];
  bool closed = false;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  Future<void> get ready => _ready.future;

  @override
  void add(Object frame) => sent.add(frame);

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  /// The server accepts the connection.
  void open() {
    _ready.complete();
    _clock.flushMicrotasks();
  }

  /// The connection attempt fails.
  void fail(Object error) {
    _ready.completeError(error);
    _clock.flushMicrotasks();
  }

  /// The server sends a frame.
  void receive(Object frame) {
    if (!_incoming.isClosed) _incoming.add(frame);
    _clock.flushMicrotasks();
  }

  /// The connection is lost.
  void drop([int code = 1006, String reason = '']) {
    closeCode = code;
    closeReason = reason;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    _clock.flushMicrotasks();
  }
}

void main() {
  late List<FakeConnection> sockets;
  WebSocketConnection connector(Uri url, Iterable<String>? protocols) {
    final socket = FakeConnection(url, protocols);
    sockets.add(socket);
    return socket;
  }

  const fast = WebSocketReconnect(
    baseDelay: Duration(milliseconds: 5),
    jitter: false,
  );
  final clients = <WebSocketClient<Object?>>[];
  void flush() => _clock.flushMicrotasks();
  void wait(int ms) => _clock.elapse(Duration(milliseconds: ms));

  /// Runs [body] in fake time, then disposes the clients it tracked.
  void fakeTest(String name, void Function() body) {
    test(name, () {
      fakeAsync((clock) {
        _clock = clock;
        sockets = [];
        clients.clear();
        try {
          body();
        } finally {
          for (final client in clients) {
            unawaited(client.dispose());
          }
          clock.flushMicrotasks();
        }
      });
    });
  }

  group('WebSocketClient', () {
    fakeTest('queues sends until open, then flushes in order with JSON framing',
        () {
      final ws = WebSocketClient<Object?>(url: 'ws://x', connector: connector);
      clients.add(ws);
      ws.connect();
      flush();
      expect(ws.send({'a': 1}), isFalse);
      expect(ws.send('raw'), isFalse);
      expect(ws.queued, 2);
      sockets.last.open();
      expect(sockets.last.sent, ['{"a":1}', 'raw']);
      expect(ws.queued, 0);
      expect(ws.send({'b': 2}), isTrue);
    });

    fakeTest('maxQueue drops the oldest; 0 disables queueing', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        maxQueue: 2,
      );
      clients.add(ws);
      ws.connect();
      flush();
      ws
        ..send('1')
        ..send('2')
        ..send('3');
      sockets.last.open();
      expect(sockets.last.sent, ['2', '3']);

      final none = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        maxQueue: 0,
      );
      clients.add(none);
      none.send('lost');
      expect(none.queued, 0);
    });

    fakeTest('decodes JSON text, passes non-JSON text and bytes through', () {
      final ws = WebSocketClient<Object?>(url: 'ws://x', connector: connector);
      clients.add(ws);
      final got = <Object?>[];
      ws.messages.listen(got.add);
      ws.connect();
      flush();
      sockets.last.open();
      sockets.last.receive('{"type":"hi"}');
      sockets.last.receive('plain');
      sockets.last.receive(<int>[1, 2]);
      expect(got[0], {'type': 'hi'});
      expect(got[1], 'plain');
      expect(got[2], isA<Uint8List>());
      expect(got[2], [1, 2]);
    });

    fakeTest('custom encode and decode are used', () {
      final ws = WebSocketClient<int>(
        url: 'ws://x',
        connector: connector,
        encode: (data) => 'out:$data',
        decode: (frame) => int.parse(frame as String),
      );
      clients.add(ws);
      final got = <int>[];
      ws.messages.listen(got.add);
      ws.connect();
      flush();
      sockets.last.open();
      ws.send(7);
      sockets.last.receive('42');
      expect(sockets.last.sent, ['out:7']);
      expect(got, [42]);
    });

    fakeTest('a throwing decode surfaces on errors and keeps the connection',
        () {
      final ws = WebSocketClient<int>(
        url: 'ws://x',
        connector: connector,
        decode: (frame) => int.parse(frame as String),
      );
      clients.add(ws);
      final errors = <Object>[];
      final got = <int>[];
      ws.errors.listen(errors.add);
      ws.messages.listen(got.add);
      ws.connect();
      flush();
      sockets.last.open();
      sockets.last.receive('not a number');
      sockets.last.receive('3');
      expect(errors.single, isA<FormatException>());
      expect(got, [3]);
      expect(ws.isOpen, isTrue);
    });

    fakeTest('a message of the wrong type surfaces on errors', () {
      final ws = WebSocketClient<int>(url: 'ws://x', connector: connector);
      clients.add(ws);
      final errors = <Object>[];
      ws.errors.listen(errors.add);
      ws.connect();
      flush();
      sockets.last.open();
      sockets.last.receive('"text"');
      expect(errors.single, isA<TypeError>());
    });

    fakeTest('reconnects with backoff after a drop and re-resolves the url',
        () {
      var n = 0;
      final ws = WebSocketClient<Object?>(
        urlProvider: () => 'ws://x?token=${++n}',
        connector: connector,
        reconnect: fast,
        protocols: const ['v1'],
      );
      clients.add(ws);
      final states = <WebSocketState>[];
      final closes = <WebSocketCloseInfo>[];
      ws.states.listen(states.add);
      ws.closes.listen(closes.add);
      ws.connect();
      flush();
      final first = sockets.last;
      expect(first.protocols, ['v1']);
      first.open();
      first.drop(1011, 'restart');
      expect(ws.state, WebSocketState.reconnecting);
      expect(first.closed, isTrue);
      expect(ws.send('while-down'), isFalse);

      wait(30);
      expect(sockets.length, 2);
      expect(sockets.last.url.toString(), 'ws://x?token=2');
      sockets.last.open();
      expect(sockets.last.sent, ['while-down']);
      expect(states, [
        WebSocketState.connecting,
        WebSocketState.open,
        WebSocketState.reconnecting,
        WebSocketState.connecting,
        WebSocketState.open,
      ]);
      expect(closes.single.code, 1011);
      expect(closes.single.reason, 'restart');
      expect(closes.single.willReconnect, isTrue);
    });

    fakeTest(
        'maxAttempts stops reconnecting; a successful open resets the count',
        () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: const WebSocketReconnect(
          baseDelay: Duration(milliseconds: 1),
          jitter: false,
          maxAttempts: 2,
        ),
      );
      clients.add(ws);
      ws.connect();
      flush();
      sockets.last.open();
      sockets.last.drop();
      wait(15);
      // Opening again resets the consecutive-failure count.
      sockets.last.open();
      sockets.last.drop();
      wait(15);
      sockets.last.drop();
      wait(15);
      expect(ws.state, WebSocketState.connecting);
      sockets.last.drop();
      expect(ws.state, WebSocketState.closed);
    });

    fakeTest('shouldReconnect can veto a reconnect', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: WebSocketReconnect(
          shouldReconnect: (code, reason) => code != 4401,
        ),
      );
      clients.add(ws);
      final closes = <WebSocketCloseInfo>[];
      ws.closes.listen(closes.add);
      ws.connect();
      flush();
      sockets.last.open();
      sockets.last.drop(4401, 'unauthorized');
      expect(ws.state, WebSocketState.closed);
      expect(closes.single.willReconnect, isFalse);
    });

    fakeTest('reconnect: null closes on drop', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: null,
      );
      clients.add(ws);
      ws.connect();
      flush();
      sockets.last.open();
      sockets.last.drop();
      expect(ws.state, WebSocketState.closed);
    });

    fakeTest('a failed connection attempt reports the error and retries', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: fast,
      );
      clients.add(ws);
      final errors = <Object>[];
      ws.errors.listen(errors.add);
      ws.connect();
      flush();
      sockets.last.fail(StateError('refused'));
      expect(errors.single, isA<StateError>());
      expect(ws.state, WebSocketState.reconnecting);
      wait(30);
      expect(sockets.length, 2);
    });

    fakeTest('a throwing urlProvider reports the error and retries', () {
      var calls = 0;
      final ws = WebSocketClient<Object?>(
        urlProvider: () {
          if (calls++ == 0) throw StateError('no token');
          return 'ws://x';
        },
        connector: connector,
        reconnect: fast,
      );
      clients.add(ws);
      final errors = <Object>[];
      ws.errors.listen(errors.add);
      ws.connect();
      flush();
      expect(errors.single, isA<StateError>());
      wait(30);
      expect(sockets.length, 1);
    });

    fakeTest('close() is final; late socket events are ignored', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: fast,
      );
      clients.add(ws);
      final got = <Object?>[];
      final closes = <WebSocketCloseInfo>[];
      ws.messages.listen(got.add);
      ws.closes.listen(closes.add);
      ws.connect();
      flush();
      final socket = sockets.last;
      socket.open();
      ws.send('queued-after-close-is-dropped');
      unawaited(ws.close());
      flush();
      expect(socket.closed, isTrue);
      socket.receive('late');
      socket.drop();
      wait(30);
      expect(sockets.length, 1);
      expect(got, isEmpty);
      expect(ws.state, WebSocketState.closed);
      expect(closes.single.willReconnect, isFalse);
      expect(closes.single.code, 1000);

      // connect() starts over after a close.
      ws.connect();
      flush();
      expect(sockets.length, 2);
    });

    fakeTest('close() cancels a pending reconnect and drops the queue', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: fast,
      );
      clients.add(ws);
      ws.connect();
      flush();
      sockets.last.open();
      sockets.last.drop();
      ws.send('pending');
      unawaited(ws.close());
      flush();
      expect(ws.queued, 0);
      wait(30);
      expect(sockets.length, 1);
    });

    fakeTest('connect() is a no-op while connecting or reconnecting', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: fast,
      );
      clients.add(ws);
      ws
        ..connect()
        ..connect();
      flush();
      expect(sockets.length, 1);
    });

    fakeTest('heartbeat pings when idle and drops a silent connection', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: null,
        heartbeat: const WebSocketHeartbeat(
          interval: Duration(milliseconds: 20),
          timeout: Duration(milliseconds: 30),
          message: {'type': 'ping'},
        ),
      );
      clients.add(ws);
      final errors = <Object>[];
      ws.errors.listen(errors.add);
      ws.connect();
      flush();
      final socket = sockets.last;
      socket.open();
      wait(30);
      expect(socket.sent, ['{"type":"ping"}']);
      socket.receive('{"type":"pong"}');
      wait(15);
      expect(ws.state, WebSocketState.open);
      wait(90);
      expect(ws.state, WebSocketState.closed);
      expect(errors.single, isA<TimeoutException>());
    });

    fakeTest('heartbeat messageBuilder is called for each ping', () {
      var n = 0;
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        heartbeat: WebSocketHeartbeat(
          interval: const Duration(milliseconds: 10),
          timeout: const Duration(seconds: 5),
          messageBuilder: () => 'ping-${++n}',
        ),
      );
      clients.add(ws);
      ws.connect();
      flush();
      sockets.last.open();
      wait(40);
      expect(sockets.last.sent.take(2), ['ping-1', 'ping-2']);
    });

    fakeTest('connect timeout fails the attempt', () {
      final ws = WebSocketClient<Object?>(
        url: 'ws://x',
        connector: connector,
        reconnect: null,
        connectTimeout: const Duration(milliseconds: 10),
      );
      clients.add(ws);
      final errors = <Object>[];
      ws.errors.listen(errors.add);
      ws.connect();
      wait(30);
      expect(ws.state, WebSocketState.closed);
      expect(errors.single, isA<TimeoutException>());
      expect(sockets.last.closed, isTrue);
    });

    fakeTest('dispose closes the streams and makes connect a no-op', () {
      final ws = WebSocketClient<Object?>(url: 'ws://x', connector: connector);
      var statesDone = false;
      unawaited(ws.states.drain<void>().whenComplete(() => statesDone = true));
      ws.connect();
      flush();
      unawaited(ws.dispose());
      flush();
      expect(statesDone, isTrue);
      ws.connect();
      flush();
      expect(sockets.length, 1);
      clients.add(ws);
    });
  });
}
