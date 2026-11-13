import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CancelToken dispose & listener lifecycle', () {
    test('unregister removes the listener', () {
      final token = CancelToken();
      final remove = token.addListener((_) {});
      expect(token.listenerCount, 1);
      remove();
      expect(token.listenerCount, 0);
    });

    test('cancel clears listeners after firing them', () {
      final token = CancelToken();
      var fired = 0;
      token.addListener((_) => fired++);
      token.cancel();
      expect(fired, 1);
      expect(token.listenerCount, 0);
      expect(token.isCancelled, true);
    });

    test('dispose clears listeners without cancelling', () {
      final token = CancelToken();
      var fired = 0;
      token.addListener((_) => fired++);
      token.dispose();
      expect(token.isDisposed, true);
      expect(token.listenerCount, 0);
      expect(fired, 0, reason: 'dispose must not fire listeners');
      expect(token.isCancelled, false);
    });

    test('cancel after dispose is a no-op', () {
      final token = CancelToken();
      token.dispose();
      token.cancel();
      expect(token.isCancelled, false);
    });

    test('addListener after dispose never registers or fires', () {
      final token = CancelToken();
      token.dispose();
      var fired = 0;
      final remove = token.addListener((_) => fired++);
      token.cancel();
      expect(fired, 0);
      expect(token.listenerCount, 0);
      // Returned unregister must be safe to call.
      remove();
    });

    test('whenCancelled does not resolve after dispose-without-cancel',
        () async {
      final token = CancelToken();
      token.dispose();
      var resolved = false;
      // ignore: unawaited_futures
      token.whenCancelled.then((_) => resolved = true);
      await Future<void>.delayed(Duration.zero);
      expect(resolved, false);
    });
  });

  group('CancelToken', () {
    test('throwIfCancelled', () {
      final t = CancelToken();
      expect(() => t.throwIfCancelled(), returnsNormally);
      t.cancel();
      expect(() => t.throwIfCancelled(), throwsA(isA<CancelError>()));
    });
  });

  group('CancelToken listener removal', () {
    test('unregistered listener is not called on cancel', () {
      final token = CancelToken();
      var fired = 0;
      final remove = token.addListener((_) => fired++);
      remove();
      token.cancel();
      expect(fired, 0);
    });

    test('listener added after cancel fires immediately', () {
      final token = CancelToken();
      token.cancel('done');
      var fired = 0;
      token.addListener((_) => fired++);
      expect(fired, 1);
    });

    test('second cancel is a no-op', () {
      final token = CancelToken();
      var fired = 0;
      token.addListener((_) => fired++);
      token.cancel();
      token.cancel();
      expect(fired, 1);
    });

    test('a listener that throws does not abort cancellation of the others',
        () {
      final token = CancelToken();
      var second = false;
      token.addListener((_) => throw StateError('rude listener'));
      token.addListener((_) => second = true);
      token.cancel(); // must not propagate the StateError
      expect(second, true, reason: 'one bad listener cannot poison the rest');
    });
  });
}
