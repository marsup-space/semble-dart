import 'dart:async';
import 'dart:isolate';

import 'isolate_server.dart';
import 'protocol.dart';

class SembleIsolateException implements Exception {
  final String message;
  final String? stack;

  const SembleIsolateException(this.message, {this.stack});

  @override
  String toString() => 'SembleIsolateException: $message';
}

class SembleSearchIsolate {
  final Isolate _isolate;
  final SendPort _sendPort;

  SembleSearchIsolate._(this._isolate, this._sendPort);

  static Future<SembleSearchIsolate> spawn({
    required String modelPath,
    required String tokenizerPath,
    required String grammarsLibPath,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      sembleSearchIsolateMain,
      ready.sendPort,
    );
    final sendPort = await ready.first.timeout(timeout) as SendPort;
    ready.close();
    final client = SembleSearchIsolate._(isolate, sendPort);

    final response = await client._request(
      (replyPort) => BootstrapReq(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        grammarsLibPath: grammarsLibPath,
        replyPort: replyPort,
      ),
      timeout: timeout,
    );
    if (response is! ReadyMsg) {
      throw StateError('unexpected bootstrap response: $response');
    }
    return client;
  }

  Future<List<SearchResult>> search(
    String query, {
    required String path,
    int topK = 8,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _request(
      (replyPort) =>
          SearchReq(query: query, path: path, topK: topK, replyPort: replyPort),
      timeout: timeout,
    );
    return (response as SearchResp).results;
  }

  Future<List<SearchResult>> findRelated({
    required String file,
    required int line,
    required String path,
    int topK = 8,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _request(
      (replyPort) => FindRelatedReq(
        file: file,
        line: line,
        path: path,
        topK: topK,
        replyPort: replyPort,
      ),
      timeout: timeout,
    );
    return (response as FindRelatedResp).results;
  }

  Future<void> prewarm(
    String path, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _request(
      (replyPort) => PrewarmReq(path: path, replyPort: replyPort),
      timeout: timeout,
    );
    if (response is! AckMsg) {
      throw StateError('unexpected prewarm response: $response');
    }
  }

  void refresh(String path) {
    _sendPort.send(RefreshReq(path: path));
  }

  Future<void> shutdown({Duration timeout = const Duration(seconds: 5)}) async {
    final response = await _request(
      (replyPort) => ShutdownReq(replyPort: replyPort),
      timeout: timeout,
    );
    if (response is! AckMsg) {
      throw StateError('unexpected shutdown response: $response');
    }
    _isolate.kill(priority: Isolate.immediate);
  }

  Future<SembleResponse> _request(
    SembleRequest Function(SendPort replyPort) build, {
    required Duration timeout,
  }) async {
    final receivePort = ReceivePort();
    try {
      _sendPort.send(build(receivePort.sendPort));
      final response = await receivePort.first.timeout(timeout);
      if (response is ErrorMsg) {
        throw SembleIsolateException(response.message, stack: response.stack);
      }
      if (response is! SembleResponse) {
        throw StateError('unexpected isolate response: $response');
      }
      return response;
    } finally {
      receivePort.close();
    }
  }
}
