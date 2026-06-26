import 'dart:async';
import 'dart:isolate';

import 'package:semble_dart/src/protocol.dart';
import 'package:test/test.dart';

/// Helper: create a [SendPort] that completes [completer] with the first
/// message it receives, then closes itself. Standard pattern for testing
/// message-passing protocols without spawning a real isolate.
SendPort _captureReply(Completer<Object?> completer) {
  late RawReceivePort rp;
  rp = RawReceivePort((message) {
    if (!completer.isCompleted) completer.complete(message);
    rp.close();
  });
  return rp.sendPort;
}

void main() {
  group('SearchResult', () {
    test('toJson produces upstream-compatible field names', () {
      const r = SearchResult(
        filePath: 'lib/auth/login.dart',
        startLine: 10,
        endLine: 25,
        score: 0.8542,
        content: 'class LoginService {}',
      );
      expect(r.toJson(), {
        'file_path': 'lib/auth/login.dart',
        'start_line': 10,
        'end_line': 25,
        'score': 0.8542,
        'content': 'class LoginService {}',
      });
    });

    test('toString surfaces file + range + score', () {
      const r = SearchResult(
        filePath: 'a.dart',
        startLine: 1,
        endLine: 5,
        score: 0.9,
        content: 'x',
      );
      expect(r.toString(), 'SearchResult(a.dart:1-5, score=0.9)');
    });
  });

  group('SembleRequest hierarchy', () {
    test('every request subtype is a SembleRequest', () {
      // Exhaustive list — adding a new SembleRequest subtype will fail
      // to compile this list, which is the point: we want the test to
      // break when the protocol surface changes so we remember to update
      // isolate_server.dart's dispatcher too.
      final reply = _captureReply(Completer<Object?>());

      final SembleRequest r1 = BootstrapReq(
        modelPath: 'm',
        tokenizerPath: 't',
        grammarsLibPath: 'g',
        replyPort: reply,
      );
      final SembleRequest r2 = SearchReq(
        query: 'auth',
        path: '.',
        topK: 8,
        replyPort: reply,
      );
      final SembleRequest r3 = FindRelatedReq(
        file: 'lib/x.dart',
        line: 1,
        path: '.',
        topK: 8,
        replyPort: reply,
      );
      final SembleRequest r4 = PrewarmReq(path: '.', replyPort: reply);
      final SembleRequest r5 = RefreshReq(path: '.');
      final SembleRequest r6 = ShutdownReq(replyPort: reply);

      expect(r1, isA<BootstrapReq>());
      expect(r2, isA<SearchReq>());
      expect(r3, isA<FindRelatedReq>());
      expect(r4, isA<PrewarmReq>());
      expect(r5, isA<RefreshReq>());
      expect(r6, isA<ShutdownReq>());
    });

    test('PrewarmReq replyPort is optional (fire-and-forget at boot)', () {
      const PrewarmReq p = PrewarmReq(path: '.');
      expect(p.replyPort, isNull);
    });
  });

  group('SembleResponse hierarchy', () {
    test('ReadyMsg and AckMsg are zero-payload', () {
      const r1 = ReadyMsg();
      const r2 = AckMsg();
      expect(r1, isA<SembleResponse>());
      expect(r2, isA<SembleResponse>());
    });

    test('SearchResp and FindRelatedResp hold results', () {
      const results = [
        SearchResult(
          filePath: 'a.dart',
          startLine: 1,
          endLine: 5,
          score: 0.9,
          content: 'x',
        ),
      ];
      const r1 = SearchResp(results);
      const r2 = FindRelatedResp(results);
      expect(r1.results, hasLength(1));
      expect(r2.results, hasLength(1));
      expect(r1.results.first.filePath, 'a.dart');
    });

    test('ErrorMsg carries message + optional stack', () {
      const e1 = ErrorMsg('boom');
      expect(e1.message, 'boom');
      expect(e1.stack, isNull);

      const e2 = ErrorMsg('boom', stack: 'trace');
      expect(e2.message, 'boom');
      expect(e2.stack, 'trace');
    });
  });
}