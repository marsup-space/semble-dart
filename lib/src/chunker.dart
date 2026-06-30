import 'treesitter/bindings.dart';
import 'treesitter/parser.dart';

/// A source chunk ready for indexing.
class CodeChunk {
  final String filePath;
  final String language;
  final int startLine;
  final int endLine;
  final int startByte;
  final int endByte;
  final String content;
  final String nodeType;
  final bool isDefinition;

  const CodeChunk({
    required this.filePath,
    required this.language,
    required this.startLine,
    required this.endLine,
    required this.startByte,
    required this.endByte,
    required this.content,
    required this.nodeType,
    required this.isDefinition,
  });
}

/// AST-aware chunker backed by tree-sitter.
///
/// Track B keeps this intentionally conservative: split on top-level named
/// nodes and merge adjacent small nodes when a grammar exposes signature/body
/// as siblings. Track C can enrich this with language-specific strategies once
/// indexing and search are in place.
class AstChunker {
  static const int defaultMinChunkBytes = 80;

  final TreeSitter treeSitter;
  final int minChunkBytes;

  const AstChunker({
    required this.treeSitter,
    this.minChunkBytes = defaultMinChunkBytes,
  });

  List<CodeChunk> chunk(ParsedSource parsed) {
    final root = parsed.root();
    final rootStart = treeSitter.startByte(root);
    final rootEnd = treeSitter.endByte(root);
    final children = treeSitter
        .namedChildrenOf(root)
        .where((node) => _hasContent(node))
        .toList();

    if (children.isEmpty) {
      return [
        _chunkForNode(
          parsed,
          root,
          startByte: rootStart,
          endByte: rootEnd,
          nodeType: treeSitter.nodeTypeString(root),
        ),
      ];
    }

    final ranges = <_NodeRange>[];
    _NodeRange? pending;
    for (final child in children) {
      final current = _NodeRange(
        startByte: treeSitter.startByte(child),
        endByte: treeSitter.endByte(child),
        nodeType: treeSitter.nodeTypeString(child),
      );
      if (pending == null) {
        pending = current;
        continue;
      }
      if (_shouldMerge(pending, current)) {
        pending = pending.merge(current);
      } else {
        ranges.add(pending);
        pending = current;
      }
    }
    if (pending != null) ranges.add(pending);

    return [for (final range in ranges) _chunkForRange(parsed, range)];
  }

  bool _hasContent(TSNode node) =>
      treeSitter.endByte(node) > treeSitter.startByte(node);

  bool _shouldMerge(_NodeRange a, _NodeRange b) {
    if (a.length >= minChunkBytes) return false;
    if (_isDefinitionNode(a.nodeType)) return false;
    return b.startByte >= a.endByte;
  }

  CodeChunk _chunkForNode(
    ParsedSource parsed,
    TSNode node, {
    required int startByte,
    required int endByte,
    required String nodeType,
  }) {
    return _chunkForRange(
      parsed,
      _NodeRange(startByte: startByte, endByte: endByte, nodeType: nodeType),
    );
  }

  CodeChunk _chunkForRange(ParsedSource parsed, _NodeRange range) {
    final start = range.startByte.clamp(0, parsed.source.length);
    final end = range.endByte.clamp(start, parsed.source.length);
    return CodeChunk(
      filePath: parsed.path,
      language: parsed.language,
      startLine: _lineForByte(parsed.source, start),
      endLine: _lineForByte(parsed.source, end),
      startByte: start,
      endByte: end,
      content: parsed.source.substring(start, end).trimRight(),
      nodeType: range.nodeType,
      isDefinition: _isDefinitionNode(range.nodeType),
    );
  }

  static int _lineForByte(String source, int byteOffset) {
    var line = 1;
    final limit = byteOffset.clamp(0, source.length);
    for (var i = 0; i < limit; i++) {
      if (source.codeUnitAt(i) == 0x0a) line++;
    }
    return line;
  }

  static bool _isDefinitionNode(String nodeType) {
    return nodeType.contains('class') ||
        nodeType.contains('function') ||
        nodeType.contains('method') ||
        nodeType.contains('constructor') ||
        nodeType.contains('declaration') ||
        nodeType.contains('definition');
  }
}

class _NodeRange {
  final int startByte;
  final int endByte;
  final String nodeType;

  const _NodeRange({
    required this.startByte,
    required this.endByte,
    required this.nodeType,
  });

  int get length => endByte - startByte;

  _NodeRange merge(_NodeRange other) {
    return _NodeRange(
      startByte: startByte,
      endByte: other.endByte,
      nodeType: nodeType == other.nodeType
          ? nodeType
          : '$nodeType+${other.nodeType}',
    );
  }
}
