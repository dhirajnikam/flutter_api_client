import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiResult.when', () {
    test('calls success branch on Success', () {
      const result = Success<int>(42, statusCode: 200);
      final out = result.when(success: (d) => 'ok:$d', failure: (_) => 'fail');
      expect(out, 'ok:42');
    });

    test('calls failure branch on Failure', () {
      const result = Failure<int>(NetworkError('down'));
      final out =
          result.when(success: (_) => 'ok', failure: (e) => 'err:${e.message}');
      expect(out, 'err:down');
    });
  });

  group('ApiResult.map', () {
    test('passes failure through unchanged', () {
      const err = TimeoutError('timed out');
      const result = Failure<int>(err);
      final mapped = result.map((d) => d * 2);
      expect(mapped, isA<Failure<int>>());
      expect((mapped as Failure<int>).error, err);
    });
  });

  group('ApiResult convenience getters', () {
    test('data returns value on Success', () {
      const r = Success<int>(42, statusCode: 200, headers: {'x-id': '1'});
      expect(r.data, 42);
      expect(r.error, isNull);
      expect(r.errorMessage, isNull);
      expect(r.statusCode, 200);
      expect(r.headers, {'x-id': '1'});
    });

    test('data returns null on Failure', () {
      const r = Failure<int>(HttpError('not found', statusCode: 404));
      expect(r.data, isNull);
      expect(r.error, isA<HttpError>());
      expect(r.errorMessage, 'not found');
      expect(r.statusCode, 404);
      expect(r.headers, <String, String>{});
    });

    test('HttpError headers are exposed via ApiResult.headers', () {
      const r = Failure<int>(
        HttpError('boom', statusCode: 500, headers: {'x-trace': 'abc'}),
      );
      expect(r.headers, {'x-trace': 'abc'});
    });
  });

  group('ApiException subtypes', () {
    test('NetworkError toString contains message', () {
      const e = NetworkError('socket closed');
      expect(e.toString(), contains('socket closed'));
    });
  });

  // =========================================================================
  // ApiResult ALGEBRA. The sealed result must behave under map/when
  // on both branches, especially preserving header/status data across map.
  // =========================================================================
  group('ApiResult algebra invariants', () {
    test('map on Success transforms data and preserves status + headers', () {
      const r = Success<int>(2, statusCode: 200, headers: {'x': 'y'});
      final mapped = r.map((d) => d * 10);
      expect(mapped.data, 20);
      expect(mapped.statusCode, 200);
      expect(mapped.headers, {'x': 'y'});
    });

    test('map on Failure passes the error through unchanged and keeps headers',
        () {
      const r = Failure<int>(
        HttpError('boom', statusCode: 500, headers: {'retry-after': '5'}),
      );
      final mapped = r.map((d) => d.toString());
      expect(mapped.isFailure, true);
      expect(mapped.statusCode, 500);
      expect(mapped.headers, {'retry-after': '5'},
          reason: 'header data on a mapped Failure must not be silently lost');
    });

    test('transport Failure (no HttpError) has null status and empty headers',
        () {
      const r = Failure<int>(NetworkError('offline'));
      expect(r.statusCode, isNull);
      expect(r.headers, isEmpty);
      expect(r.errorMessage, 'offline');
    });
  });

  group('ApiResult ergonomics', () {
    const ok = Success<int>(2, statusCode: 200);
    const bad = Failure<int>(HttpError('nope', statusCode: 400));

    test('flatMap chains success and short-circuits failure', () {
      final chained =
          ok.flatMap((v) => Success<String>('v$v', statusCode: 200));
      expect(chained.data, 'v2');

      final rejected =
          ok.flatMap<String>((v) => const Failure(ParseError('bad shape')));
      expect(rejected.error, isA<ParseError>());

      var called = false;
      final skipped = bad.flatMap<String>((v) {
        called = true;
        return Success<String>('$v', statusCode: 200);
      });
      expect(called, isFalse);
      expect(skipped.error, isA<HttpError>());
      expect(skipped.statusCode, 400, reason: 'failure status carried over');
    });

    test('mapError transforms only the failure branch', () {
      final wrapped = bad
          .mapError((e) => UnknownError('user-facing: ${e.message}', cause: e));
      expect(wrapped.errorMessage, 'user-facing: nope');
      expect(ok.mapError((e) => const UnknownError('x')).data, 2);
    });

    test('getOrElse returns data or the fallback', () {
      expect(ok.getOrElse((_) => -1), 2);
      expect(bad.getOrElse((e) => -1), -1);
    });

    test('onSuccess/onFailure tap the right branch and chain', () {
      final log = <String>[];
      final result = ok
          .onSuccess((v) => log.add('ok:$v'))
          .onFailure((e) => log.add('err'));
      expect(log, ['ok:2']);
      expect(result.data, 2, reason: 'taps return the result unchanged');

      log.clear();
      bad.onSuccess((v) => log.add('ok')).onFailure((e) => log.add('err'));
      expect(log, ['err']);
    });
  });
}
