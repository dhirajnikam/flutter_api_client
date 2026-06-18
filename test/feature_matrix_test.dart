// Feature-completeness verification (work item w4, grace-hopper).
//
// Every other advertised feature already has a passing test (see the
// feature->evidence matrix in .teammates/FINAL.md). The ONE advertised feature
// that had no direct coverage was upload/download PROGRESS callbacks
// (`onSendProgress` / `onReceiveProgress`, advertised in the README feature
// table and the library doc). This file closes that gap by driving the real
// DefaultHttpAdapter end-to-end through the public ApiClient with an injected
// fake http.Client, and asserting the progress contract holds.

import 'dart:async';

import 'package:flutter_api_client/flutter_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Streams a body in discrete chunks with a known Content-Length, so the
/// adapter's receive loop reports incremental download progress.
class _ChunkedClient extends http.BaseClient {
  _ChunkedClient(this.chunks);
  final List<List<int>> chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final controller = StreamController<List<int>>();
    () async {
      for (final c in chunks) {
        controller.add(c);
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
    }();
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: total,
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

ApiClient _clientWith(http.Client inner) => ApiClient(
      ApiClientConfig(
        baseUrl: 'https://api.example.com',
        adapter: DefaultHttpAdapter(client: inner),
      ),
    );

void main() {
  group('Feature: download progress (onReceiveProgress)', () {
    test('fires incrementally and reaches the full content length', () async {
      // '{"ok":true}' split across three chunks (11 bytes total).
      final chunks = <List<int>>[
        '{"ok'.codeUnits,
        '":tr'.codeUnits,
        'ue}'.codeUnits,
      ];
      final total = chunks.fold<int>(0, (s, c) => s + c.length);

      final received = <int>[];
      int? reportedTotal;
      final client = _clientWith(_ChunkedClient(chunks));

      final res = await client.get<Map<String, dynamic>>(
        'thing',
        options: RequestOptions(
          onReceiveProgress: (r, t) {
            received.add(r);
            reportedTotal = t;
          },
        ),
      );

      expect(res.isSuccess, true);
      expect(res.data, {'ok': true});
      expect(received, isNotEmpty, reason: 'progress must be reported');
      expect(received.last, total,
          reason: 'cumulative received reaches the body size');
      expect(reportedTotal, total, reason: 'total is the Content-Length');
      // Monotonic non-decreasing progress.
      for (var i = 1; i < received.length; i++) {
        expect(received[i] >= received[i - 1], true);
      }
    });
  });

  group('Feature: upload progress (onSendProgress)', () {
    test('reports sent bytes reaching the request body size', () async {
      final sent = <int>[];
      int? reportedTotal;
      final client = _clientWith(_ChunkedClient(['{}'.codeUnits]));

      final res = await client.post<Map<String, dynamic>>(
        'thing',
        {'hello': 'world'},
        options: RequestOptions(
          onSendProgress: (s, t) {
            sent.add(s);
            reportedTotal = t;
          },
        ),
      );

      expect(res.isSuccess, true);
      expect(sent, isNotEmpty, reason: 'send progress must be reported');
      expect(reportedTotal, isNotNull);
      expect(reportedTotal! > 0, true, reason: 'encoded body has a length');
      expect(sent.last, reportedTotal,
          reason: 'final sent equals the total body size');
    });
  });
}
