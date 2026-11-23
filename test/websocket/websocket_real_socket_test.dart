@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart' hide within;

import '../support/liveness.dart';

/// Exercises the default `web_socket_channel` transport against a real
/// loopback server (the other tests use a fake connection).
void main() {
  group('WebSocketClient over a real socket', () {
    test('echo round trip, then a clean close', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen(socket.add, onDone: socket.close);
      });

      final ws = WebSocketClient<Object?>(
        url: 'ws://127.0.0.1:${server.port}',
        reconnect: null,
      );
      final reply = ws.messages.first;
      ws
        ..send({'n': 42})
        ..connect();
      expect(await within(reply), {'n': 42});
      expect(ws.state, WebSocketState.open);
      await within(ws.dispose());
      expect(ws.state, WebSocketState.closed);
    });

    test('server closing the socket triggers a reconnect', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var connections = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        if (++connections == 1) {
          await socket.close(4000, 'bye');
        } else {
          socket.add('"welcome back"');
        }
      });

      final ws = WebSocketClient<Object?>(
        url: 'ws://127.0.0.1:${server.port}',
        reconnect: const WebSocketReconnect(
          baseDelay: Duration(milliseconds: 10),
          jitter: false,
        ),
      );
      addTearDown(ws.dispose);
      final firstClose = ws.closes.first;
      final message = ws.messages.first;
      ws.connect();
      final close = await within(firstClose);
      expect(close.code, 4000);
      expect(close.reason, 'bye');
      expect(close.willReconnect, isTrue);
      expect(await within(message), 'welcome back');
      expect(connections, 2);
    });

    test('a refused connection reports an error and schedules a retry',
        () async {
      // Bind then close to get a port nothing listens on.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      final ws = WebSocketClient<Object?>(
        url: 'ws://127.0.0.1:$port',
        reconnect: const WebSocketReconnect(baseDelay: Duration(seconds: 30)),
      );
      final error = ws.errors.first;
      final close = ws.closes.first;
      ws.connect();
      expect(await within(error), isNotNull);
      expect((await within(close)).willReconnect, isTrue);
      expect(ws.state, WebSocketState.reconnecting);
      await within(ws.dispose());
    });

    test('close() and dispose() return while an attempt is still connecting',
        () async {
      // Accepts the TCP connection but never answers the upgrade.
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      silent.listen(accepted.add);
      addTearDown(() async {
        for (final s in accepted) {
          s.destroy();
        }
        await silent.close();
      });

      final ws = WebSocketClient<Object?>(
        url: 'ws://127.0.0.1:${silent.port}',
        reconnect: null,
      );
      ws.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ws.state, WebSocketState.connecting);
      await within(ws.close());
      expect(ws.state, WebSocketState.closed);
      await within(ws.dispose());
    });
  });
}
