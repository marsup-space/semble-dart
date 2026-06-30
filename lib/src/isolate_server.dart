import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'cache.dart';
import 'chunker.dart';
import 'index.dart';
import 'model.dart';
import 'protocol.dart';
import 'tokenizer.dart';
import 'treesitter/bindings.dart';
import 'treesitter/parser.dart';

Future<void> sembleSearchIsolateMain(SendPort parentPort) async {
  final receivePort = ReceivePort();
  parentPort.send(receivePort.sendPort);

  final server = _SembleSearchServer(receivePort);
  await server.run();
}

class _SembleSearchServer {
  final ReceivePort receivePort;
  final Map<String, SembleIndex> _indexes = {};

  EmbeddingModel? _model;
  WordPieceTokenizer? _tokenizer;
  TreeSitter? _treeSitter;
  TreeSitterParser? _parser;
  AstChunker? _chunker;

  _SembleSearchServer(this.receivePort);

  Future<void> run() async {
    await for (final message in receivePort) {
      if (message is! SembleRequest) continue;
      switch (message) {
        case BootstrapReq():
          await _reply(message.replyPort, () async {
            await _bootstrap(message);
            return const ReadyMsg();
          });
        case SearchReq():
          await _reply(message.replyPort, () async {
            final index = await _ensureIndex(message.path);
            return SearchResp(index.search(message.query, topK: message.topK));
          });
        case FindRelatedReq():
          await _reply(message.replyPort, () async {
            final index = await _ensureIndex(message.path);
            final root = p.normalize(p.absolute(message.path));
            final file = p.isAbsolute(message.file)
                ? p.normalize(message.file)
                : p.normalize(p.join(root, message.file));
            return FindRelatedResp(
              index.findRelated(
                file: file,
                line: message.line,
                topK: message.topK,
              ),
            );
          });
        case PrewarmReq():
          await _handlePrewarm(message);
        case RefreshReq():
          await _handleRefresh(message);
        case ShutdownReq():
          await _reply(message.replyPort, () async {
            _treeSitter?.close();
            receivePort.close();
            return const AckMsg();
          });
      }
    }
  }

  Future<void> _bootstrap(BootstrapReq req) async {
    if (req.modelPath.isNotEmpty || req.tokenizerPath.isNotEmpty) {
      if (req.modelPath.isEmpty || req.tokenizerPath.isEmpty) {
        throw ArgumentError('modelPath and tokenizerPath must be paired');
      }
      final tokenizerJson =
          jsonDecode(await File(req.tokenizerPath).readAsString())
              as Map<String, dynamic>;
      _tokenizer = WordPieceTokenizer.fromJson(tokenizerJson);
      _model = await EmbeddingModel.fromFile(req.modelPath);
    }

    _treeSitter = await TreeSitter.load(
      path: req.grammarsLibPath.isEmpty ? null : req.grammarsLibPath,
    );
    _parser = TreeSitterParser(_treeSitter!);
    _chunker = AstChunker(treeSitter: _treeSitter!);
  }

  Future<SembleIndex> _ensureIndex(String rootPath) async {
    final parser = _parser;
    final chunker = _chunker;
    if (parser == null || chunker == null) {
      throw StateError('search isolate has not been bootstrapped');
    }

    final root = p.normalize(p.absolute(rootPath));
    final cached = _indexes[root];
    if (cached != null) return cached;

    final index = await SembleIndex.fromPath(
      rootPath: root,
      parser: parser,
      chunker: chunker,
      cache: SembleCache(p.join(root, '.dart_tool', 'semble_cache')),
      model: _model,
      tokenizer: _tokenizer,
    );
    _indexes[root] = index;
    return index;
  }

  Future<void> _handlePrewarm(PrewarmReq req) async {
    final replyPort = req.replyPort;
    if (replyPort == null) {
      try {
        await _ensureIndex(req.path);
      } catch (_) {
        // Fire-and-forget prewarm errors are surfaced by the next request.
      }
      return;
    }

    await _reply(replyPort, () async {
      await _ensureIndex(req.path);
      return const AckMsg();
    });
  }

  Future<void> _handleRefresh(RefreshReq req) async {
    final root = p.normalize(p.absolute(req.path));
    _indexes.remove(root);
    try {
      await _ensureIndex(root);
    } catch (_) {
      // Refresh is fire-and-forget; the next search will report failures.
    }
  }

  Future<void> _reply(
    SendPort replyPort,
    Future<SembleResponse> Function() action,
  ) async {
    try {
      replyPort.send(await action());
    } catch (error, stack) {
      replyPort.send(ErrorMsg(error.toString(), stack: stack.toString()));
    }
  }
}
